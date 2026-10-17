@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Observation
import RealityKit
import SplattyCore
import UIKit

/// Drives one guided capture: ARKit configuration, object anchor, ring guidance,
/// one auto-shot per uncovered bin, and handing shots to `ShotWriter`.
@MainActor
@Observable
final class CaptureController: NSObject, ARCaptureHost {
    enum Phase: Equatable {
        /// Waiting for the user to tap the object centre.
        case placing
        /// Guided orbit.
        case capturing
        /// Plan complete; user can finish or keep going.
        case done
    }

    // MARK: UI state (updated at most ~10 Hz)
    private(set) var phase: Phase = .placing
    private(set) var shotCount = 0
    private(set) var depthShotCount = 0
    private(set) var coverage: CoverageMap
    private(set) var hint: GuidanceHint?
    private(set) var ringProgress: [RingProgress] = []
    private(set) var skippedRings: Set<ElevationRing> = []
    /// Why the last useful frame was not shot (shown in red).
    private(set) var rejection: CaptureWarning?
    /// Set right after a ring completes; the view shows a "next ring" card.
    private(set) var completedRing: ElevationRing?
    private(set) var trackingIsNormal = false
    private(set) var trackingText = "正在启动相机…"
    private(set) var currentDistance: Double?
    private(set) var isSaving = false
    private(set) var lastError: String?
    private(set) var videoFormatLabel = ""
    private(set) var savedResolutionLabel = ""
    private(set) var shutterFlash = 0
    private(set) var exposureLocked = false
    private(set) var exposureLockAvailable = false
    /// After "可以了", the user chose to keep shooting remaining bins.
    private(set) var keepGoing = false
    let depthSupported: Bool
    let highResSupported: Bool
    private(set) var depthEnabled: Bool

    let settings: CaptureSettings
    let plan: CapturePlan
    private(set) var meta: AssetMeta

    var targetShots: Int { plan.targetShots(skipping: skippedRings) }
    var activeRing: ElevationRing? { hint?.activeRing ?? plan.activeRing(coverage, skipped: skippedRings) }

    // MARK: Internal state
    @ObservationIgnored private weak var arView: ARView?
    private let writer: ShotWriter
    private let device: DeviceInfo
    @ObservationIgnored private let haptics = Haptics()
    @ObservationIgnored private var records: [FrameRecord] = []
    @ObservationIgnored private var nextIndex = 1
    @ObservationIgnored private var anchor: Vec3?
    @ObservationIgnored private var ringGuide: RingGuide?
    @ObservationIgnored private var motion = MotionEstimator()
    @ObservationIgnored private var gate = GuidedShotGate()
    @ObservationIgnored private var lastShotTime: Double?
    @ObservationIgnored private var lastRejectionTime: Double = 0
    @ObservationIgnored private var lastUIUpdate: Double = 0
    @ObservationIgnored private var completedRingTime: Double = 0
    @ObservationIgnored private var useHighRes: Bool
    @ObservationIgnored var onMetaChanged: (@MainActor (AssetMeta) -> Void)?
    @ObservationIgnored private var log = CaptureLog(captureMode: CaptureMode.orbit.rawValue,
                                                     startedAt: AssetNaming.iso8601(Date(), timeZone: .current))
    @ObservationIgnored private var lastLoggedRejection: CaptureWarning?
    @ObservationIgnored private var videoFormat: ARConfiguration.VideoFormat?

    init(meta: AssetMeta, layout: AssetLayout, settings: CaptureSettings) {
        self.meta = meta
        self.settings = settings
        plan = settings.plan
        coverage = CoverageMap(plan: settings.plan)
        writer = ShotWriter(layout: layout, format: settings.imageFormat, quality: settings.quality)
        depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        highResSupported = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
        depthEnabled = settings.depthEnabled && depthSupported
        useHighRes = settings.highResolution && highResSupported
        exposureLockAvailable = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera != nil
        device = DeviceInfo.current()
        super.init()
        ringProgress = plan.progress(coverage)
        do { try writer.prepareDirectories() } catch { lastError = error.localizedDescription }
    }

    // MARK: - Session lifecycle

    func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        view.session.delegateQueue = .main
        haptics.prepare()
        runConfiguration(reset: true)
    }

    func handleTap(at point: CGPoint, in view: ARView) {
        setAnchor(at: point, in: view)
    }

    func stop() {
        if exposureLocked { setExposureLocked(false) }
        arView?.session.pause()
    }

    /// Toggle LiDAR scene depth; re-runs the session without resetting tracking.
    func setDepthEnabled(_ on: Bool) {
        let value = on && depthSupported
        guard value != depthEnabled else { return }
        depthEnabled = value
        runConfiguration(reset: false)
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if useHighRes, let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        } else if let best = Self.highestResolutionBackWideFormat() {
            config.videoFormat = best
        }
        config.isAutoFocusEnabled = true
        config.isLightEstimationEnabled = true
        config.planeDetection = [.horizontal]
        if depthEnabled, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        videoFormat = config.videoFormat
        let r = config.videoFormat.imageResolution
        videoFormatLabel = "\(Int(r.width))×\(Int(r.height))@\(config.videoFormat.framesPerSecond)"
            + (useHighRes ? " + hi-res" : "")
        return config
    }

    /// Largest back wide-angle format (e.g. 4K on supported devices).
    private static func highestResolutionBackWideFormat() -> ARConfiguration.VideoFormat? {
        ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.captureDevicePosition == .back && $0.captureDeviceType == .builtInWideAngleCamera }
            .max { a, b in
                a.imageResolution.width * a.imageResolution.height < b.imageResolution.width * b.imageResolution.height
            }
    }

    private func runConfiguration(reset: Bool) {
        guard let session = arView?.session else { return }
        let options: ARSession.RunOptions = reset ? [.resetTracking, .removeExistingAnchors] : []
        session.run(makeConfiguration(), options: options)
        if reset {
            motion.reset()
            lastShotTime = nil
        }
    }

    // MARK: - Exposure / white-balance lock

    /// Locks exposure + white balance (focus stays continuous so distance changes are OK).
    func setExposureLocked(_ locked: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
            device.unlockForConfiguration()
            exposureLocked = locked
        } catch {
            lastError = "锁定曝光失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Object anchor / phases

    /// Tap → raycast to estimated geometry; fall back to 30 cm along the tap ray.
    func setAnchor(at point: CGPoint, in view: ARView) {
        guard phase == .placing else { return } // taps only pick the centre while placing
        guard trackingIsNormal else {
            lastError = "相机还在初始化，左右慢慢晃一下手机再点"
            return
        }
        var target: Vec3?
        if let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            let c = hit.worldTransform.columns.3
            target = Vec3(Double(c.x), Double(c.y), Double(c.z))
        } else if let ray = view.ray(through: point) {
            target = Vec3(ray.origin + ray.direction * 0.3)
        }
        guard let target else { return }
        placeAnchor(target, in: view)
    }

    /// "就是中间这个" button: raycast from the screen centre.
    func setAnchorAtCenter() {
        guard let view = arView else { return }
        setAnchor(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    /// Back to placing (keeps shots; they are re-binned around the new centre).
    func replaceAnchor() {
        phase = .placing
    }

    private func placeAnchor(_ p: Vec3, in view: ARView) {
        anchor = p
        lastError = nil
        ringGuide?.remove(from: view)
        // Ring radius scales with how far away the user stands (object size proxy).
        let camPos = view.session.currentFrame.map { Mat4($0.camera.transform).translation }
        let dist = camPos.map { ($0 - p).length } ?? 0.3
        let radius = Float(min(0.18, max(0.06, dist * 0.3)))
        ringGuide = RingGuide(anchor: p, radius: radius, in: view)
        // Re-bin existing shots around the new centre.
        var map = CoverageMap(plan: plan)
        for i in records.indices {
            let cell = map.record(cameraToWorld: records[i].transform, anchor: p)
            records[i].ring = cell?.ring.rawValue
            records[i].azimuthBin = cell?.bin
        }
        coverage = map
        ringProgress = plan.progress(coverage, skipped: skippedRings)
        phase = plan.isComplete(coverage, skipped: skippedRings) ? .done : .capturing
        if exposureLockAvailable, !exposureLocked { setExposureLocked(true) }
    }

    /// "这圈拍不了，跳过".
    func skipActiveRing() {
        guard let r = plan.activeRing(coverage, skipped: skippedRings) else { return }
        skippedRings.insert(r)
        ringProgress = plan.progress(coverage, skipped: skippedRings)
        completedRing = nil
        if plan.isComplete(coverage, skipped: skippedRings) { enterDone() }
    }

    func dismissRingCard() { completedRing = nil }

    /// After "可以了": keep filling the remaining bins.
    func continueShooting() {
        keepGoing = true
        phase = .capturing
    }

    private func enterDone() {
        phase = .done
        keepGoing = false
        haptics.success()
    }

    // MARK: - Per-frame processing (main queue)

    private func process(_ frame: ARFrame) {
        let pose = Mat4(frame.camera.transform)
        let now = frame.timestamp
        let tracking = TrackingQuality(frame.camera.trackingState)
        motion.update(pose: pose, timestamp: now)

        guard let anchor, phase != .placing else {
            if now - lastUIUpdate > 0.1 {
                lastUIUpdate = now
                updateTrackingText(tracking)
            }
            return
        }

        let distance = (pose.translation - anchor).length
        // Blur is judged at streaming resolution (~1920 px wide), roughly the
        // resolution msplat trains at after downscaling.
        let blur = BlurModel.estimatedBlurPixels(
            angularSpeedDegPerSec: motion.angularSpeed,
            linearSpeed: motion.linearSpeed,
            exposureDuration: frame.camera.exposureDuration,
            focalLengthPixels: Double(frame.camera.intrinsics.columns.0.x),
            objectDistance: distance
        )
        let aimed = PoseMath.offAxisAngleDegrees(pose, target: anchor) <= coverage.maxOffAxisDegrees
        let quality = FrameQualityInput(
            tracking: tracking,
            ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) },
            exposureDuration: frame.camera.exposureDuration,
            estimatedBlurPixels: blur,
            angularSpeed: motion.angularSpeed,
            aimedAtObject: aimed,
            distance: distance
        )
        let h = Guidance.hint(cameraToWorld: pose, anchor: anchor, coverage: coverage, plan: plan, skipped: skippedRings)
        let autoOn = phase == .capturing

        if autoOn {
            switch gate.decide(hint: h, quality: quality, captureInFlight: isSaving, now: now, lastShotTime: lastShotTime) {
            case .fire:
                rejection = nil
                shoot(frame)
            case .rejected(let w):
                rejection = w
                lastRejectionTime = now
                if w != lastLoggedRejection {
                    log.add("rejected", w.message, t: now)
                    lastLoggedRejection = w
                }
            case .idle:
                if rejection != nil, now - lastRejectionTime > 1.2 { rejection = nil }
            }
        }

        // Hide the "next ring" card once the user reached the next ring (or after a while).
        if let _ = completedRing, let cell = h.currentCell, cell.ring == h.activeRing, now - completedRingTime > 1.5 {
            completedRing = nil
        } else if completedRing != nil, now - completedRingTime > 8 {
            completedRing = nil
        }

        if now - lastUIUpdate > 0.1 {
            lastUIUpdate = now
            hint = h
            currentDistance = distance
            updateTrackingText(tracking)
            ringGuide?.update(coverage: coverage, ring: h.activeRing, targetBin: h.targetBin)
        }
    }

    private func updateTrackingText(_ tracking: TrackingQuality) {
        trackingIsNormal = tracking.isNormal
        switch tracking {
        case .normal: trackingText = ""
        case .limited(let r): trackingText = CaptureStrings.trackingReason(r)
        case .notAvailable: trackingText = CaptureStrings.trackingReason("not available")
        }
    }

    /// Manual shutter (always allowed, even in covered bins).
    func shutter() {
        guard let frame = arView?.session.currentFrame, anchor != nil else { return }
        shoot(frame)
    }

    private func shoot(_ frame: ARFrame) {
        guard !isSaving, let session = arView?.session else { return }
        isSaving = true
        let index = nextIndex
        nextIndex += 1
        let stream = ShotPayload.StreamSource(frame: frame)
        let depth = depthEnabled ? ShotPayload.DepthSource(frame: frame) : nil
        let capturedAt = AssetNaming.iso8601(Date(), timeZone: .current)
        let includeDepth = depthEnabled
        lastShotTime = frame.timestamp
        lastLoggedRejection = nil
        log.add("shot", "#\(index) \(TurntableCaptureController.cameraState())", t: frame.timestamp)
        shutterFlash += 1
        haptics.shot()
        // Mark the bin immediately so we never fire twice in it while saving.
        if let anchor { coverage.record(cameraToWorld: stream.pose, anchor: anchor) }
        afterCoverageChange()
        let writer = self.writer

        guard useHighRes else {
            writer.write(ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)) { result in
                Task { @MainActor in self.finish(result, provisionalPose: stream.pose) }
            }
            return
        }
        TurntableCaptureController.captureHighRes(session: session, format: videoFormat) { hiFrame, error in
            let payload: ShotPayload
            if let hiFrame {
                payload = ShotPayload(index: index, highResFrame: hiFrame, includeDepth: includeDepth,
                                      fallbackDepth: depth, fallbackFeatures: stream.featurePoints,
                                      capturedAt: capturedAt)
            } else {
                // Fall back to the streaming frame captured at trigger time.
                payload = ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)
                let message = error?.localizedDescription ?? "unknown"
                Task { @MainActor in self.lastError = "高清拍摄失败（\(message)），已保存视频帧" }
            }
            writer.write(payload) { result in
                Task { @MainActor in self.finish(result, provisionalPose: stream.pose) }
            }
        }
    }

    /// Ring / plan completion bookkeeping after the coverage map changed.
    private func afterCoverageChange() {
        let before = ringProgress
        ringProgress = plan.progress(coverage, skipped: skippedRings)
        let newlyDone = zip(before, ringProgress).first { !$0.0.isComplete && $0.1.isComplete }?.1.ring
        if plan.isComplete(coverage, skipped: skippedRings) {
            if phase == .capturing, !keepGoing { enterDone() }
        } else if let r = newlyDone {
            completedRing = r
            completedRingTime = arView?.session.currentFrame?.timestamp ?? 0
            haptics.success()
        }
    }

    private func finish(_ result: Result<FrameRecord, Error>, provisionalPose: Mat4) {
        isSaving = false
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
            // Free the bin again so the user can retake it.
            rebuildCoverage(extraPose: nil)
        case .success(var record):
            if let anchor, let cell = coverage.cell(cameraToWorld: record.transform, anchor: anchor) {
                record.ring = cell.ring.rawValue
                record.azimuthBin = cell.bin
            }
            records.append(record)
            // The hi-res pose can differ slightly from the trigger pose; rebuild from saved poses.
            rebuildCoverage(extraPose: nil)
            shotCount = records.count
            depthShotCount = records.filter { $0.depthFilePath != nil }.count
            savedResolutionLabel = "\(record.intrinsics.width)×\(record.intrinsics.height)"
            persist()
        }
    }

    private func rebuildCoverage(extraPose: Mat4?) {
        guard let anchor else { return }
        var map = CoverageMap(plan: plan)
        for r in records { map.record(cameraToWorld: r.transform, anchor: anchor) }
        if let extraPose { map.record(cameraToWorld: extraPose, anchor: anchor) }
        // Never lose a bin we already showed as covered while a save was pending.
        coverage = map
        ringProgress = plan.progress(coverage, skipped: skippedRings)
    }

    private func persist() {
        meta.status = records.isEmpty ? .draft : .captured
        meta.capturedAt = AssetNaming.iso8601(Date(), timeZone: .current)
        meta.timeZone = TimeZone.current.identifier
        meta.counts = AssetCounts(images: shotCount, depth: depthShotCount)
        meta.device = device
        meta.appVersion = DeviceInfo.appVersion
        meta.capture = CaptureSettingsRecord(
            targetShots: targetShots,
            imageFormat: settings.imageFormat.rawValue,
            highResolutionFrames: useHighRes,
            depthEnabled: depthEnabled,
            videoFormat: videoFormatLabel,
            exposureLocked: exposureLocked
        )
        meta.capture?.captureMode = .orbit
        meta.capture?.preset = settings.planPreset.rawValue
        if let d = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            meta.capture?.whiteBalanceLocked = d.whiteBalanceMode == .locked
            meta.capture?.focusLocked = d.focusMode == .locked
        }
        meta.schemaVersion = AssetMeta.currentSchemaVersion
        meta.captureMode = .orbit
        meta.posesValid = true
        let snapshot = meta
        onMetaChanged?(snapshot)
        writer.persist(frames: records, anchor: anchor, meta: snapshot, log: log) { error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = "保存元数据失败：\(message)" }
        }
    }
}

// MARK: - ARSessionDelegate

extension CaptureController: ARSessionDelegate {
    // ARKit calls these on `delegateQueue`, which we set to the main queue.
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.process(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.lastError = "AR 会话失败：\(message)" }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.trackingText = "已中断，回到 App 后会继续" }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
