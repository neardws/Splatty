@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Observation
import RealityKit
import SplattyCore
import UIKit

/// Drives one capture session: ARKit configuration, quality gating,
/// coverage tracking and handing shots to `ShotWriter`.
@MainActor
@Observable
final class CaptureController: NSObject {
    // MARK: UI state (updated at most ~10 Hz)
    private(set) var shotCount = 0
    private(set) var depthShotCount = 0
    private(set) var coverage = CoverageMap()
    private(set) var warnings: [CaptureWarning] = []
    private(set) var trackingLabel = "starting"
    private(set) var currentCell: (ring: ElevationRing, bin: Int)?
    private(set) var currentDistance: Double?
    private(set) var anchorIsUserSet = false
    private(set) var isSaving = false
    private(set) var lastError: String?
    private(set) var videoFormatLabel = ""
    private(set) var savedResolutionLabel = ""
    private(set) var shutterFlash = 0
    private(set) var exposureLocked = false
    private(set) var exposureLockAvailable = false
    let depthSupported: Bool
    let highResSupported: Bool
    var autoCapture = false
    private(set) var depthEnabled: Bool

    let settings: CaptureSettings
    private(set) var meta: AssetMeta

    // MARK: Internal state
    @ObservationIgnored private weak var arView: ARView?
    private let writer: ShotWriter
    @ObservationIgnored private var records: [FrameRecord] = []
    @ObservationIgnored private var nextIndex = 1
    @ObservationIgnored private var anchor: Vec3?
    @ObservationIgnored private var anchorEntity: AnchorEntity?
    @ObservationIgnored private var motion = MotionEstimator()
    @ObservationIgnored private var gate = AutoCaptureGate()
    @ObservationIgnored private var lastShot: (pose: Mat4, time: Double)?
    @ObservationIgnored private var lastUIUpdate: Double = 0
    private let device: DeviceInfo
    @ObservationIgnored private var useHighRes: Bool
    @ObservationIgnored var onMetaChanged: (@MainActor (AssetMeta) -> Void)?

    init(meta: AssetMeta, layout: AssetLayout, settings: CaptureSettings) {
        self.meta = meta
        self.settings = settings
        writer = ShotWriter(layout: layout, format: settings.imageFormat, quality: settings.quality)
        depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        highResSupported = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing != nil
        depthEnabled = settings.depthEnabled && depthSupported
        useHighRes = settings.highResolution && highResSupported
        exposureLockAvailable = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera != nil
        device = DeviceInfo.current()
        super.init()
        do { try writer.prepareDirectories() } catch { lastError = error.localizedDescription }
    }

    var targetShots: Int { settings.targetShots }

    // MARK: - Session lifecycle

    func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        view.session.delegateQueue = .main
        runConfiguration(reset: true)
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
        let r = config.videoFormat.imageResolution
        videoFormatLabel = "\(Int(r.width))×\(Int(r.height))@\(config.videoFormat.framesPerSecond)"
            + (useHighRes ? " + hi-res stills" : "")
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
            lastShot = nil
        }
    }

    // MARK: - Exposure / focus / white-balance lock

    func setExposureLocked(_ locked: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            lastError = "This device doesn't expose camera controls to ARKit"
            return
        }
        do {
            try device.lockForConfiguration()
            if locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            device.unlockForConfiguration()
            exposureLocked = locked
        } catch {
            lastError = "Camera lock failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Object anchor

    /// Tap → raycast to estimated geometry; fall back to 30 cm along the tap ray.
    func setAnchor(at point: CGPoint, in view: ARView) {
        let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first
        if let hit {
            let c = hit.worldTransform.columns.3
            placeAnchor(Vec3(Double(c.x), Double(c.y), Double(c.z)), userSet: true)
        } else if let ray = view.ray(through: point) {
            placeAnchor(Vec3(ray.origin + ray.direction * 0.3), userSet: true)
        }
    }

    private func placeAnchor(_ p: Vec3, userSet: Bool) {
        anchor = p
        anchorIsUserSet = userSet
        if let old = anchorEntity { arView?.scene.removeAnchor(old) }
        let entity = AnchorEntity(world: p.simd)
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.006),
                              materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)])
        entity.addChild(dot)
        arView?.scene.addAnchor(entity)
        anchorEntity = entity
        // Re-bin existing shots around the new centre.
        var map = CoverageMap()
        for i in records.indices {
            let cell = map.record(cameraToWorld: records[i].transform, anchor: p)
            records[i].ring = cell?.ring.rawValue
            records[i].azimuthBin = cell?.bin
        }
        coverage = map
    }

    // MARK: - Per-frame processing (main queue)

    private func process(_ frame: ARFrame) {
        let pose = Mat4(frame.camera.transform)
        let now = frame.timestamp
        let tracking = TrackingQuality(frame.camera.trackingState)
        motion.update(pose: pose, timestamp: now)

        if anchor == nil, tracking.isNormal {
            placeAnchor(PoseMath.point(inFrontOf: pose, distance: 0.3), userSet: false)
        }

        // Blur is judged at streaming resolution (~1920 px wide), roughly the
        // resolution msplat trains at after downscaling.
        let fx = Double(frame.camera.intrinsics.columns.0.x)
        let distance = anchor.map { (pose.translation - $0).length } ?? 0.3
        let blur = BlurModel.estimatedBlurPixels(
            angularSpeedDegPerSec: motion.angularSpeed,
            linearSpeed: motion.linearSpeed,
            exposureDuration: frame.camera.exposureDuration,
            focalLengthPixels: fx,
            objectDistance: distance
        )
        let aimed = anchor.map { PoseMath.offAxisAngleDegrees(pose, target: $0) <= coverage.maxOffAxisDegrees } ?? true
        let quality = FrameQualityInput(
            tracking: tracking,
            ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) },
            exposureDuration: frame.camera.exposureDuration,
            estimatedBlurPixels: blur,
            angularSpeed: motion.angularSpeed,
            aimedAtObject: aimed
        )

        if autoCapture,
           gate.decide(current: pose, now: now, lastShot: lastShot, quality: quality, captureInFlight: isSaving) == .fire {
            shoot(frame)
        }

        if now - lastUIUpdate > 0.1 {
            lastUIUpdate = now
            warnings = CaptureQuality.warnings(quality, thresholds: gate.thresholds)
            trackingLabel = tracking.label
            if let anchor {
                currentCell = coverage.cell(cameraToWorld: pose, anchor: anchor)
                currentDistance = distance
            }
        }
    }

    /// Manual shutter.
    func shutter() {
        guard let frame = arView?.session.currentFrame else { return }
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
        lastShot = (stream.pose, frame.timestamp)
        shutterFlash += 1
        let writer = self.writer

        guard useHighRes else {
            writer.write(ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)) { result in
                Task { @MainActor in self.finish(result) }
            }
            return
        }
        session.captureHighResolutionFrame { hiFrame, error in
            let payload: ShotPayload
            if let hiFrame {
                payload = ShotPayload(index: index, highResFrame: hiFrame, includeDepth: includeDepth,
                                      fallbackDepth: depth, fallbackFeatures: stream.featurePoints,
                                      capturedAt: capturedAt)
            } else {
                // Fall back to the streaming frame captured at trigger time.
                payload = ShotPayload(index: index, stream: stream, depth: depth, capturedAt: capturedAt)
                let message = error?.localizedDescription ?? "unknown"
                Task { @MainActor in self.lastError = "Hi-res capture failed (\(message)); saved video frame" }
            }
            writer.write(payload) { result in
                Task { @MainActor in self.finish(result) }
            }
        }
    }

    private func finish(_ result: Result<FrameRecord, Error>) {
        isSaving = false
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
        case .success(var record):
            if let anchor, let cell = coverage.record(cameraToWorld: record.transform, anchor: anchor) {
                record.ring = cell.ring.rawValue
                record.azimuthBin = cell.bin
            }
            records.append(record)
            shotCount = records.count
            depthShotCount = records.filter { $0.depthFilePath != nil }.count
            savedResolutionLabel = "\(record.intrinsics.width)×\(record.intrinsics.height)"
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
        meta.capture = CaptureSettingsRecord(
            targetShots: settings.targetShots,
            imageFormat: settings.imageFormat.rawValue,
            highResolutionFrames: useHighRes,
            depthEnabled: depthEnabled,
            videoFormat: videoFormatLabel,
            exposureLocked: exposureLocked
        )
        let snapshot = meta
        onMetaChanged?(snapshot)
        writer.persist(frames: records, anchor: anchor, meta: snapshot) { error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in self.lastError = "Saving metadata failed: \(message)" }
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
        MainActor.assumeIsolated { self.lastError = "AR session failed: \(message)" }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            self.autoCapture = false
            self.trackingLabel = "interrupted"
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}
