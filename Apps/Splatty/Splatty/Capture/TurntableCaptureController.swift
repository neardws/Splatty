@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Observation
import RealityKit
import SplattyCore
import UIKit

/// Anything that drives an `ARCaptureView`.
@MainActor
protocol ARCaptureHost: AnyObject {
    func attach(to view: ARView)
    func stop()
    func handleTap(at point: CGPoint, in view: ARView)
}

/// Turntable capture (default mode): the user sits still, keeps the phone roughly in
/// front, and turns the object. No markers. The object's rotation is estimated from the
/// image (see `RotationTracker`); ARKit is only used for phone motion, phone height
/// (elevation) and gravity. Poses are recovered on the Mac with COLMAP.
@MainActor
@Observable
final class TurntableCaptureController: NSObject, ARCaptureHost {
    enum Phase: Equatable {
        /// 10-second tips card (patterned paper, soft light, phone stand).
        case tips
        /// Waiting for a tap on the object.
        case placing
        case capturing
        case done
    }

    // MARK: UI state
    private(set) var phase: Phase = .tips
    private(set) var shotCount = 0
    private(set) var depthShotCount = 0
    private(set) var maskCount = 0
    private(set) var coverage: TurntableCoverage
    private(set) var activeRing: TurntableRing? = .eye
    /// Set right after a ring completes (card + voice); cleared when the next height is reached.
    private(set) var completedRing: TurntableRing?
    /// Ring-relative estimated object rotation (0–360) for the dial.
    private(set) var ringAngle: Double = 0
    private(set) var turnSpeed: Double = 0
    private(set) var issue: TurntableIssue?
    private(set) var rotationReliable = true
    private(set) var elevation: Double?
    /// Clockwise rotation for the portrait-locked overlay (0, 90, 180, -90).
    private(set) var uiRotation = 0
    /// Object window in normalized view coordinates (for the yellow box).
    private(set) var roiViewRect: CGRect?
    private(set) var trackingIsNormal = false
    private(set) var trackingText = "正在启动相机…"
    private(set) var isSaving = false
    private(set) var lastError: String?
    private(set) var shutterFlash = 0
    private(set) var skippedRings: Set<TurntableRing> = []
    private(set) var keepGoing = false
    private(set) var exposureLocked = false
    var voiceEnabled: Bool {
        didSet {
            voice.enabled = voiceEnabled
            if !voiceEnabled { voice.stop() }
            UserDefaults.standard.set(voiceEnabled, forKey: CaptureSettings.Keys.voice)
        }
    }

    let plan: TurntablePlan
    let settings: CaptureSettings
    let depthSupported: Bool
    private(set) var meta: AssetMeta
    var targetShots: Int { plan.targetShots(skipping: skippedRings) }

    // MARK: Internal
    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private let writer: ShotWriter
    @ObservationIgnored private let analyzer = TurntableAnalyzer()
    @ObservationIgnored private let device: DeviceInfo
    @ObservationIgnored private let haptics = Haptics()
    @ObservationIgnored private let voice: VoiceCoach
    @ObservationIgnored private var gate: TurntableShotGate
    @ObservationIgnored private var tracker = RotationTracker()
    @ObservationIgnored private var change = ChangeDetector()
    @ObservationIgnored private var coach = TurntableCoach()
    @ObservationIgnored private var rotationResolver = UIRotationResolver()
    @ObservationIgnored private var motion = MotionEstimator()
    @ObservationIgnored private var log: CaptureLog
    @ObservationIgnored private var records: [FrameRecord] = []
    @ObservationIgnored private var pending: [Int: ShotInfo] = [:]
    @ObservationIgnored private var nextIndex = 1
    @ObservationIgnored private var anchor: Vec3?
    /// Object box relative to the projected object centre, stream pixels, at `roiRefDistance`.
    @ObservationIgnored private var roiRel = PixelRect(minX: -150, minY: -150, maxX: 150, maxY: 150)
    @ObservationIgnored private var roiRefDistance = 0.35
    /// Quantized scale applied to `roiRel` (changes force a new keyframe).
    @ObservationIgnored private var roiScale = 1.0
    @ObservationIgnored private var analysisInFlight = false
    @ObservationIgnored private var lastAnalysisTime = 0.0
    @ObservationIgnored private var pendingRekey = false
    @ObservationIgnored private var resetKey = true
    @ObservationIgnored private var simpleModeAnnounced = false
    @ObservationIgnored private var lastShotTime: Double?
    @ObservationIgnored private var lastUIUpdate = 0.0
    @ObservationIgnored private var sessionStart: Double?
    @ObservationIgnored private var completedRingTime = 0.0
    @ObservationIgnored private var lastLoggedIssue: TurntableIssue?
    @ObservationIgnored private var useHighRes: Bool
    @ObservationIgnored private var depthEnabled: Bool
    @ObservationIgnored private var videoFormat: ARConfiguration.VideoFormat?
    @ObservationIgnored private var videoFormatLabel = ""
    @ObservationIgnored private var whiteBalanceLocked = false
    @ObservationIgnored private var focusLocked = false
    @ObservationIgnored var onMetaChanged: (@MainActor (AssetMeta) -> Void)?

    private struct ShotInfo {
        var ring: TurntableRing
        var bin: Int
        var progress: Double
        var elevation: Double
        var upright: Int
        var orientation: String
        var gravity: Vec3
        var anchorPx: Vec2?
        var distance: Double
        /// Stream image size (anchorPx coordinates).
        var streamWidth: Int
        var streamHeight: Int
    }

    init(meta: AssetMeta, layout: AssetLayout, settings: CaptureSettings) {
        self.meta = meta
        self.settings = settings
        plan = settings.turntablePlan
        coverage = TurntableCoverage(plan: settings.turntablePlan)
        gate = TurntableShotGate(plan: settings.turntablePlan)
        writer = ShotWriter(layout: layout, format: settings.imageFormat, quality: settings.quality, mode: .turntable)
        depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        depthEnabled = settings.depthEnabled && depthSupported
        useHighRes = settings.highResolution
            && ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
        device = DeviceInfo.current()
        voice = VoiceCoach(enabled: settings.voice)
        voiceEnabled = settings.voice
        log = CaptureLog(captureMode: CaptureMode.turntable.rawValue,
                         startedAt: AssetNaming.iso8601(Date(), timeZone: .current))
        super.init()
        do { try writer.prepareDirectories() } catch { lastError = error.localizedDescription }
    }

    // MARK: - Session

    func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        view.session.delegateQueue = .main
        haptics.prepare()
        let config = makeConfiguration()
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        log.add("info", "video \(videoFormatLabel), hiRes=\(useHighRes), depth=\(depthEnabled)", t: 0)
    }

    func stop() {
        voice.stop()
        unlockCamera()
        arView?.session.pause()
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if useHighRes, let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = f
        }
        config.isAutoFocusEnabled = true
        config.isLightEstimationEnabled = true
        config.planeDetection = [.horizontal]
        if depthEnabled { config.frameSemantics.insert(.sceneDepth) }
        videoFormat = config.videoFormat
        let r = config.videoFormat.imageResolution
        videoFormatLabel = "\(Int(r.width))×\(Int(r.height))@\(config.videoFormat.framesPerSecond)" + (useHighRes ? " + hi-res" : "")
        return config
    }

    // MARK: - Phases

    func finishTips() {
        guard phase == .tips else { return }
        phase = .placing
    }

    func handleTap(at point: CGPoint, in view: ARView) {
        guard phase == .placing else { return }
        guard trackingIsNormal, let frame = view.session.currentFrame else {
            lastError = "相机还在初始化，左右轻轻晃一下手机再点"
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
        start(anchor: target, frame: frame)
    }

    func tapCenter() {
        guard let view = arView else { return }
        handleTap(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY), in: view)
    }

    private func start(anchor a: Vec3, frame: ARFrame) {
        anchor = a
        lastError = nil
        let pose = Mat4(frame.camera.transform)
        let k = Intrinsics(frame.camera)
        let distance = max(0.08, (pose.translation - a).length)
        roiRefDistance = distance
        let r = TurntableGeometry.assumedRadiusPixels(distance: distance, focal: k.fx)
        roiRel = PixelRect(center: Vec2(0, 0), halfWidth: r, halfHeight: r)
        roiScale = 1
        resetKey = true
        let center = TurntableGeometry.project(a, cameraToWorld: pose, intrinsics: k)
        if let center {
            let hint = CGPoint(x: center.x / Double(k.width), y: center.y / Double(k.height))
            lockCamera(at: hint)
            detectSubject(frame.capturedImage, hint: hint, anchorPx: center, width: k.width, height: k.height, distance: distance)
        }
        phase = .capturing
        activeRing = coverage.activeRing(skipping: skippedRings)
        coach.noteProgress(frame.timestamp)
        speak(.start(.eye))
        log.add("info", "object centre set, distance \(String(format: "%.2f", distance)) m", t: rel(frame.timestamp))
    }

    /// Initial object box from Vision subject lifting (off the main thread).
    private func detectSubject(_ image: CVPixelBuffer, hint: CGPoint, anchorPx: Vec2, width: Int, height: Int, distance: Double) {
        let boxed = UncheckedSendable(image)
        DispatchQueue.global(qos: .userInitiated).async {
            let det = try? SubjectMasker.detect(boxed.value, hint: hint)
            let box = det?.box
            Task { @MainActor in
                guard let box else { return }
                self.updateROI(normalizedBox: box, anchorPx: anchorPx, width: width, height: height, distance: distance)
            }
        }
    }

    private func updateROI(normalizedBox b: CGRect, anchorPx: Vec2, width: Int, height: Int, distance: Double) {
        let W = Double(width), H = Double(height)
        let box = PixelRect(minX: b.minX * W, minY: b.minY * H, maxX: b.maxX * W, maxY: b.maxY * H)
        // Ignore absurd boxes (whole frame, specks).
        guard box.width > 40, box.height > 40, box.width < W * 0.95, box.height < H * 0.95 else { return }
        roiRel = box.offset(by: Vec2(-anchorPx.x, -anchorPx.y))
        roiRefDistance = distance
        roiScale = 1
        resetKey = true
    }

    func skipActiveRing() {
        guard let r = coverage.activeRing(skipping: skippedRings) else { return }
        skippedRings.insert(r)
        log.add("info", "skipped ring \(r.key)", t: -1)
        afterCoverageChange(now: arView?.session.currentFrame?.timestamp ?? 0, before: r)
    }

    func dismissRingCard() { completedRing = nil }

    func continueShooting() {
        keepGoing = true
        phase = .capturing
    }

    /// Back to tapping the object (keeps shots).
    func replaceAnchor() {
        phase = .placing
    }

    // MARK: - Camera lock

    /// Single-shot AF/AE at the object, then lock focus, exposure and white balance so all
    /// views share the same exposure (3DGS hates brightness changes between views).
    private func lockCamera(at p: CGPoint) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            log.add("exposure", "no configurable capture device; exposure NOT locked", t: -1)
            return
        }
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = p }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = p }
            if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            device.unlockForConfiguration()
        } catch {
            lastError = "对焦失败：\(error.localizedDescription)"
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            self.applyLocks(true)
        }
    }

    private func applyLocks(_ on: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if on {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            device.unlockForConfiguration()
        } catch {
            log.add("error", "lockForConfiguration: \(error.localizedDescription)", t: -1)
        }
        exposureLocked = device.exposureMode == .locked
        whiteBalanceLocked = device.whiteBalanceMode == .locked
        focusLocked = device.focusMode == .locked
        log.add("exposure", Self.cameraState(), t: -1)
    }

    private func unlockCamera() {
        if exposureLocked || whiteBalanceLocked || focusLocked { applyLocks(false) }
    }

    /// Refocus once for the new height, keep exposure / white balance locked.
    private func refocus() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              device.isFocusModeSupported(.autoFocus) else { return }
        do {
            try device.lockForConfiguration()
            device.focusMode = .autoFocus
            device.unlockForConfiguration()
        } catch { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            self.applyLocks(true)
        }
    }

    /// Actual AVCaptureDevice state, logged with every shot to verify the locks hold
    /// (also for high-resolution stills).
    static func cameraState() -> String {
        guard let d = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return "no device" }
        func name(_ m: AVCaptureDevice.ExposureMode) -> String {
            switch m {
            case .locked: "locked"
            case .autoExpose: "auto-once"
            case .continuousAutoExposure: "continuous"
            case .custom: "custom"
            @unknown default: "?"
            }
        }
        let wb = d.whiteBalanceMode == .locked ? "locked" : "auto"
        let af = d.focusMode == .locked ? "locked" : (d.focusMode == .autoFocus ? "auto-once" : "continuous")
        return String(format: "AE=%@ WB=%@ AF=%@ ISO=%.0f exp=1/%.0f lens=%.2f",
                      name(d.exposureMode), wb, af, d.iso, 1 / max(1e-6, d.exposureDuration.seconds), d.lensPosition)
    }

    // MARK: - Per-frame

    private func rel(_ t: Double) -> Double { t - (sessionStart ?? t) }

    private func process(_ frame: ARFrame) {
        let pose = Mat4(frame.camera.transform)
        let now = frame.timestamp
        if sessionStart == nil { sessionStart = now }
        motion.update(pose: pose, timestamp: now)
        let tracking = TrackingQuality(frame.camera.trackingState)
        let rot = rotationResolver.update(upInCamera: TurntableGeometry.gravityUpInCamera(pose))
        if rot != uiRotation { uiRotation = rot }

        guard let anchor, phase == .capturing || phase == .done else {
            if now - lastUIUpdate > 0.1 {
                lastUIUpdate = now
                updateTrackingText(tracking)
            }
            return
        }

        let k = Intrinsics(frame.camera)
        let W = Double(k.width), H = Double(k.height)
        let anchorPx = TurntableGeometry.project(anchor, cameraToWorld: pose, intrinsics: k)
        let distance = max(0.05, (pose.translation - anchor).length)
        let elev = TurntableGeometry.elevationDegrees(camera: pose, objectCenter: anchor)
        let inView = anchorPx.map { $0.x > W * 0.08 && $0.x < W * 0.92 && $0.y > H * 0.08 && $0.y < H * 0.92 } ?? false
        let roi = anchorPx.map { currentROI(anchorPx: $0, distance: distance) }
        let ring = coverage.activeRing(skipping: skippedRings)
        let phoneSteady = motion.angularSpeed < 15 && motion.linearSpeed < 0.08

        // 1. Image analysis (~10 Hz, one in flight).
        if !analysisInFlight, let roi, inView, now - lastAnalysisTime >= 0.09 {
            submitAnalysis(frame: frame, crop: roi.expanded(by: 1.1), pose: pose, roi: roi,
                           phoneSteady: phoneSteady, trackAngle: ring != .top)
        }

        // 2. Shot decision.
        let progress = tracker.progressDegrees
        var inNewBin = false
        if let ring, ring != .top {
            // Only touch the observable coverage when something changes (avoid 60 Hz redraws).
            if coverage.origins[ring.rawValue] == nil { coverage.begin(ring, at: progress) }
            inNewBin = !coverage.isCovered(ring, bin: coverage.bin(ring, progressDegrees: progress))
        }
        let exposure = frame.camera.exposureDuration
        let phoneBlur = BlurModel.estimatedBlurPixels(
            angularSpeedDegPerSec: motion.angularSpeed, linearSpeed: motion.linearSpeed,
            exposureDuration: exposure, focalLengthPixels: k.fx, objectDistance: distance)
        let ambient = frame.lightEstimate.map { Double($0.ambientIntensity) }
        let dark = (ambient.map { $0.isFinite && $0 < 250 } ?? false) || exposure > 1.0 / 30
        let input = TurntableShotInput(
            activeRing: phase == .capturing ? ring : nil,
            elevation: elev.isFinite ? elev : nil,
            trackingNormal: tracking.isNormal,
            objectInView: inView,
            tooDark: dark,
            phoneAngularSpeed: motion.angularSpeed,
            phoneLinearSpeed: motion.linearSpeed,
            phoneBlurPixels: phoneBlur,
            // Top-down: the angle tracker is idle there, so sharpness comes from contentSteady.
            objectBlurPixels: ring == .top ? 0 : tracker.flowPixelsPerSecond * exposure,
            turnSpeedDegreesPerSecond: tracker.speedDegreesPerSecond,
            rotationReliable: tracker.isReliable,
            inNewBin: inNewBin,
            contentChanged: change.changedEnough,
            contentSteady: change.isSteady,
            captureInFlight: isSaving,
            now: now,
            lastShotTime: lastShotTime)
        var currentIssue: TurntableIssue?
        switch gate.decide(input) {
        case .fire:
            if let ring {
                shoot(frame, ring: ring, progress: progress, elevation: elev, pose: pose, anchorPx: anchorPx,
                      distance: distance, width: W, height: H)
            }
        case .rejected(let i):
            currentIssue = i
        case .idle:
            break
        }
        if currentIssue != lastLoggedIssue {
            if let i = currentIssue { log.add("rejected", Self.issueKey(i), t: rel(now)) }
            lastLoggedIssue = currentIssue
        }

        // 3. Voice + haptics (only while capturing, not during the ring-done card's first seconds).
        let quietAfterRing = completedRing != nil && now - completedRingTime < 3
        if phase == .capturing, !quietAfterRing,
           let cue = coach.cue(for: currentIssue, now: now, capturing: true) {
            voice.say(VoiceCoach.text(cue))
            if cue == .tooFast { haptics.doubleTap() }
        }

        // Ring-done card: hide once the phone reached the next height (or after 8 s).
        if completedRing != nil, let ring {
            let inBand = plan.heightMove(for: ring, elevation: elev) == nil
            if (inBand && now - completedRingTime > 2) || now - completedRingTime > 8 { completedRing = nil }
        }

        // 4. UI (10 Hz).
        if now - lastUIUpdate > 0.1 {
            lastUIUpdate = now
            updateTrackingText(tracking)
            issue = currentIssue
            elevation = elev.isFinite ? elev : nil
            turnSpeed = tracker.speedDegreesPerSecond
            rotationReliable = tracker.isReliable
            activeRing = ring
            if let ring, ring != .top { ringAngle = coverage.ringAngle(ring, progressDegrees: progress) }
            if let roi, let view = arView {
                let t = frame.displayTransform(for: .portrait, viewportSize: view.bounds.size)
                let n = CGRect(x: roi.minX / W, y: roi.minY / H, width: roi.width / W, height: roi.height / H)
                roiViewRect = n.applying(t).standardized
            } else {
                roiViewRect = nil
            }
        }
    }

    private func currentROI(anchorPx: Vec2, distance: Double) -> PixelRect {
        let wanted = roiRefDistance / distance
        if abs(wanted / roiScale - 1) > 0.08 {
            roiScale = wanted
            resetKey = true
        }
        return roiRel.scaled(roiScale, about: Vec2(0, 0)).offset(by: anchorPx)
    }

    private func submitAnalysis(frame: ARFrame, crop: PixelRect, pose: Mat4, roi: PixelRect, phoneSteady: Bool, trackAngle: Bool) {
        analysisInFlight = true
        lastAnalysisTime = frame.timestamp
        let req = TurntableAnalyzer.Request(image: frame.capturedImage, crop: crop, timestamp: frame.timestamp,
                                            rekeyToPrevious: pendingRekey, resetKey: resetKey)
        pendingRekey = false
        resetKey = false
        analyzer.analyze(req) { result in
            Task { @MainActor in
                self.handleAnalysis(result, pose: pose, roi: roi, phoneSteady: phoneSteady, trackAngle: trackAngle)
            }
        }
    }

    private func handleAnalysis(_ r: TurntableAnalyzer.Result, pose: Mat4, roi: PixelRect, phoneSteady: Bool, trackAngle: Bool) {
        analysisInFlight = false
        if !r.thumbnail.isEmpty { change.ingest(r.thumbnail) }
        guard trackAngle, phase == .capturing else { return }
        if r.fresh {
            tracker.didRekey()
            return
        }
        let axis = TurntableGeometry.horizontalAxis(pose)
        let radius = axis.map { TurntableGeometry.apparentRadius(box: roi, axis: $0) } ?? 0
        let wasReliable = tracker.isReliable
        let out = tracker.ingest(.init(shift: r.shift, axis: axis, radiusPixels: radius,
                                       timestamp: r.timestamp, phoneSteady: phoneSteady))
        if out.rekey { pendingRekey = true }
        if wasReliable, !tracker.isReliable {
            log.add("info", "rotation estimate unreliable → content-change trigger", t: rel(r.timestamp))
            if !simpleModeAnnounced, shotCount > 0 || tracker.acceptedSamples == 0 {
                simpleModeAnnounced = true
                speak(.switchedToSimpleMode)
            }
        } else if !wasReliable, tracker.isReliable {
            log.add("info", "rotation estimate reliable again", t: rel(r.timestamp))
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

    private func speak(_ cue: CoachCue) {
        let now = arView?.session.currentFrame?.timestamp ?? 0
        if let c = coach.say(cue, now: now) { voice.say(VoiceCoach.text(c), interrupt: cue.isMilestone) }
    }

    static func issueKey(_ i: TurntableIssue) -> String {
        switch i {
        case .tracking: "tracking"
        case .objectOutOfView: "objectOutOfView"
        case .wrongHeight(.raise): "raisePhone"
        case .wrongHeight(.lower): "lowerPhone"
        case .tooDark: "tooDark"
        case .phoneMoving: "phoneMoving"
        case .turningTooFast: "turningTooFast"
        case .holdStill: "holdStill"
        }
    }

    // MARK: - Shooting

    /// Manual shutter (counts toward the active ring).
    func shutter() {
        guard let frame = arView?.session.currentFrame, let anchor,
              let ring = coverage.activeRing(skipping: skippedRings) ?? (keepGoing ? .eye : nil) else { return }
        let pose = Mat4(frame.camera.transform)
        let k = Intrinsics(frame.camera)
        shoot(frame, ring: ring, progress: tracker.progressDegrees,
              elevation: TurntableGeometry.elevationDegrees(camera: pose, objectCenter: anchor), pose: pose,
              anchorPx: TurntableGeometry.project(anchor, cameraToWorld: pose, intrinsics: k),
              distance: (pose.translation - anchor).length, width: Double(k.width), height: Double(k.height))
    }

    private func shoot(_ frame: ARFrame, ring: TurntableRing, progress: Double, elevation: Double, pose: Mat4,
                       anchorPx: Vec2?, distance: Double, width W: Double, height H: Double) {
        guard !isSaving, let session = arView?.session else { return }
        isSaving = true
        let index = nextIndex
        nextIndex += 1
        let before = coverage.activeRing(skipping: skippedRings)
        let bin = coverage.record(ring, progressDegrees: progress)
        change.markShot()
        coach.noteProgress(frame.timestamp)
        lastShotTime = frame.timestamp
        pending[index] = ShotInfo(ring: ring, bin: bin, progress: progress, elevation: elevation,
                                  upright: TurntableGeometry.uprightRotationCW(pose),
                                  orientation: rotationResolver.orientationName,
                                  gravity: TurntableGeometry.gravityUpInCamera(pose),
                                  anchorPx: anchorPx, distance: distance,
                                  streamWidth: Int(W), streamHeight: Int(H))
        haptics.shot()
        shutterFlash += 1
        log.add("shot", String(format: "#%d %@ bin %d, rot %.0f°, elev %.0f°, %@", index, ring.key, bin,
                               progress, elevation, Self.cameraState()), t: rel(frame.timestamp))
        afterCoverageChange(now: frame.timestamp, before: before)

        let stream = ShotPayload.StreamSource(frame: frame)
        let depth = depthEnabled ? ShotPayload.DepthSource(frame: frame) : nil
        let capturedAt = AssetNaming.iso8601(Date(), timeZone: .current)
        let hint = anchorPx.map { CGPoint(x: $0.x / W, y: $0.y / H) }
        let includeDepth = depthEnabled
        let writer = self.writer

        let write: @Sendable (ShotPayload) -> Void = { payload in
            writer.writeWithMask(payload) { result in
                Task { @MainActor in self.finish(result, index: index) }
            }
        }
        guard useHighRes else {
            var p = ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)
            p.maskHint = hint
            write(p)
            return
        }
        let handler: @Sendable (ARFrame?, Error?) -> Void = { hiFrame, error in
            var payload: ShotPayload
            if let hiFrame {
                payload = ShotPayload(index: index, highResFrame: hiFrame, includeDepth: includeDepth,
                                      fallbackDepth: depth, fallbackFeatures: [], capturedAt: capturedAt)
            } else {
                payload = ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)
                let message = error?.localizedDescription ?? "unknown"
                Task { @MainActor in
                    self.lastError = "高清拍摄失败（\(message)），已保存视频帧"
                    self.log.add("error", "hi-res capture failed: \(message)", t: -1)
                }
            }
            payload.maskHint = hint
            write(payload)
        }
        Self.captureHighRes(session: session, format: videoFormat, completion: handler)
    }

    /// High-resolution still. On iOS 26+ we pass photo settings with `.speed` quality
    /// prioritization so the still is not multi-frame fused / tone-mapped differently
    /// from the locked-exposure stream (pilot renders came out brighter than photos).
    nonisolated static func captureHighRes(session: ARSession, format: ARConfiguration.VideoFormat?,
                                           completion: @escaping @Sendable (ARFrame?, Error?) -> Void) {
        if #available(iOS 26.0, *), let format {
            let settings = format.defaultPhotoSettings
            settings.photoQualityPrioritization = .speed
            settings.flashMode = .off
            session.captureHighResolutionFrame(using: settings) { frame, error in completion(frame, error) }
        } else {
            session.captureHighResolutionFrame { frame, error in completion(frame, error) }
        }
    }

    private func afterCoverageChange(now: Double, before: TurntableRing?) {
        let after = coverage.activeRing(skipping: skippedRings)
        activeRing = after
        guard after != before else { return }
        if let after {
            completedRing = before
            completedRingTime = now
            haptics.success()
            speak(.ringDone(next: after))
            coach.noteProgress(now)
            change.reset()
            refocus()
            log.add("info", "ring \(before?.key ?? "-") done → \(after.key)", t: rel(now))
        } else if phase == .capturing, !keepGoing {
            phase = .done
            haptics.success()
            speak(.allDone(shots: nextIndex - 1))
            log.add("info", "plan complete, \(nextIndex - 1) shots", t: rel(now))
        }
    }

    private func finish(_ result: Result<(FrameRecord, CGRect?), Error>, index: Int) {
        isSaving = false
        let info = pending.removeValue(forKey: index)
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
            log.add("error", "shot #\(index) not saved: \(error.localizedDescription)", t: -1)
            if let info { coverage.remove(info.ring, bin: info.bin) }
            activeRing = coverage.activeRing(skipping: skippedRings)
            if activeRing != nil, phase == .done { phase = .capturing }
        case .success(let (rec, box)):
            var record = rec
            if let info {
                record.uprightRotationCW = info.upright
                record.deviceOrientation = info.orientation
                record.gravityCamera = [info.gravity.x, info.gravity.y, info.gravity.z]
                record.objectRotationDegrees = info.ring == .top ? nil : info.progress
                record.elevationDegrees = info.elevation
                record.turntableRing = info.ring.key
                record.azimuthBin = info.ring == .top ? nil : info.bin
                if let box, let a = info.anchorPx {
                    updateROI(normalizedBox: box, anchorPx: a, width: info.streamWidth, height: info.streamHeight,
                              distance: info.distance)
                }
            }
            if box == nil { log.add("info", "no mask for shot #\(index)", t: -1) }
            records.append(record)
            shotCount = records.count
            depthShotCount = records.filter { $0.depthFilePath != nil }.count
            maskCount = records.filter { $0.maskFilePath != nil }.count
            persist()
        }
    }

    private func persist() {
        meta.status = records.isEmpty ? .draft : .captured
        meta.capturedAt = AssetNaming.iso8601(Date(), timeZone: .current)
        meta.timeZone = TimeZone.current.identifier
        meta.counts = AssetCounts(images: shotCount, depth: depthShotCount)
        meta.device = device
        meta.appVersion = DeviceInfo.appVersion
        meta.schemaVersion = AssetMeta.currentSchemaVersion
        meta.captureMode = .turntable
        meta.posesValid = false
        meta.masks = maskCount > 0 ? MaskInfo(count: maskCount) : nil
        var record = CaptureSettingsRecord(
            targetShots: targetShots,
            imageFormat: settings.imageFormat.rawValue,
            highResolutionFrames: useHighRes,
            depthEnabled: depthEnabled,
            videoFormat: videoFormatLabel,
            exposureLocked: exposureLocked)
        record.whiteBalanceLocked = whiteBalanceLocked
        record.focusLocked = focusLocked
        record.captureMode = .turntable
        record.preset = settings.planPreset.rawValue
        record.voicePrompts = voiceEnabled
        meta.capture = record
        let snapshot = meta
        onMetaChanged?(snapshot)
        writer.persist(frames: records, anchor: nil, meta: snapshot, log: log) { error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = "保存元数据失败：\(message)" }
        }
    }
}

extension TurntableCaptureController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { self.process(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.lastError = "AR 会话失败：\(message)"
            self.log.add("error", "AR session failed: \(message)", t: -1)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.trackingText = "已中断，回到 App 后会继续" }
    }
}

extension TurntableCaptureController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
