import Foundation

/// Simplified, platform-independent tracking state.
public enum TrackingQuality: Equatable, Sendable, Codable {
    case normal
    case limited(reason: String)
    case notAvailable

    public var isNormal: Bool { self == .normal }

    public var label: String {
        switch self {
        case .normal: "normal"
        case .limited(let r): "limited(\(r))"
        case .notAvailable: "notAvailable"
        }
    }
}

public enum CaptureWarning: Equatable, Hashable, Sendable {
    case trackingLimited(String)
    case tooDark
    case movingTooFast
    case notAimedAtObject

    public var message: String {
        switch self {
        case .trackingLimited(let r): "Tracking limited: \(r)"
        case .tooDark: "Too dark — add soft light"
        case .movingTooFast: "Moving too fast — slow down"
        case .notAimedAtObject: "Aim at the object marker"
        }
    }
}

/// Smoothed camera speed estimated from consecutive poses.
public struct MotionEstimator: Sendable {
    public private(set) var linearSpeed: Double = 0   // m/s
    public private(set) var angularSpeed: Double = 0  // deg/s
    /// EMA factor for the newest sample (0...1).
    public var smoothing: Double
    private var last: (pose: Mat4, time: Double)?

    public init(smoothing: Double = 0.3) { self.smoothing = smoothing }

    public mutating func update(pose: Mat4, timestamp: Double) {
        defer { last = (pose, timestamp) }
        guard let last else { return }
        let dt = timestamp - last.time
        guard dt > 1e-4, dt < 1 else { return }
        let v = PoseMath.translationDistance(last.pose, pose) / dt
        let w = PoseMath.rotationAngleDegrees(last.pose, pose) / dt
        linearSpeed += smoothing * (v - linearSpeed)
        angularSpeed += smoothing * (w - angularSpeed)
    }

    public mutating func reset() {
        last = nil
        linearSpeed = 0
        angularSpeed = 0
    }
}

public enum BlurModel {
    /// Rough motion-blur length in pixels during one exposure:
    /// rotational part ω·t·f plus translational part (v·t / depth)·f.
    public static func estimatedBlurPixels(
        angularSpeedDegPerSec: Double,
        linearSpeed: Double,
        exposureDuration: Double,
        focalLengthPixels: Double,
        objectDistance: Double
    ) -> Double {
        let omega = angularSpeedDegPerSec * .pi / 180
        let rot = omega * exposureDuration * focalLengthPixels
        let depth = max(objectDistance, 0.05)
        let trans = linearSpeed * exposureDuration / depth * focalLengthPixels
        return rot + trans
    }
}

public struct QualityThresholds: Sendable, Equatable {
    /// ARKit `ambientIntensity` (lumens, ~1000 = well lit) below which we warn.
    public var minAmbientIntensity: Double = 250
    /// Exposure time (s) above which we consider the scene too dark.
    public var maxExposureDuration: Double = 1.0 / 30.0
    /// Estimated blur (pixels at ARKit streaming resolution, ~1920 px wide)
    /// above which we warn / skip auto-capture.
    public var maxBlurPixels: Double = 4
    /// Hard angular speed cap (deg/s).
    public var maxAngularSpeed: Double = 45

    public init() {}
}

public struct FrameQualityInput: Sendable, Equatable {
    public var tracking: TrackingQuality
    public var ambientIntensity: Double?
    public var exposureDuration: Double
    public var estimatedBlurPixels: Double
    public var angularSpeed: Double
    public var aimedAtObject: Bool

    public init(
        tracking: TrackingQuality,
        ambientIntensity: Double?,
        exposureDuration: Double,
        estimatedBlurPixels: Double,
        angularSpeed: Double,
        aimedAtObject: Bool
    ) {
        self.tracking = tracking
        self.ambientIntensity = ambientIntensity
        self.exposureDuration = exposureDuration
        self.estimatedBlurPixels = estimatedBlurPixels
        self.angularSpeed = angularSpeed
        self.aimedAtObject = aimedAtObject
    }
}

public enum CaptureQuality {
    public static func warnings(_ i: FrameQualityInput, thresholds t: QualityThresholds = .init()) -> [CaptureWarning] {
        var w: [CaptureWarning] = []
        switch i.tracking {
        case .normal: break
        case .limited(let r): w.append(.trackingLimited(r))
        case .notAvailable: w.append(.trackingLimited("not available"))
        }
        let darkByLight = (i.ambientIntensity.map { $0 < t.minAmbientIntensity }) ?? false
        if darkByLight || i.exposureDuration > t.maxExposureDuration { w.append(.tooDark) }
        if i.estimatedBlurPixels > t.maxBlurPixels || i.angularSpeed > t.maxAngularSpeed { w.append(.movingTooFast) }
        if !i.aimedAtObject { w.append(.notAimedAtObject) }
        return w
    }
}

/// Decides when auto-capture should fire.
public struct AutoCaptureGate: Sendable, Equatable {
    public var minRotationDegrees: Double = 5
    public var minTranslationMeters: Double = 0.03
    public var minInterval: Double = 0.35
    public var thresholds = QualityThresholds()

    public init() {}

    public enum Decision: Equatable, Sendable {
        case fire
        case wait(String)
    }

    public func decide(
        current: Mat4,
        now: Double,
        lastShot: (pose: Mat4, time: Double)?,
        quality: FrameQualityInput,
        captureInFlight: Bool
    ) -> Decision {
        if captureInFlight { return .wait("saving") }
        guard quality.tracking.isNormal else { return .wait("tracking") }
        guard quality.estimatedBlurPixels <= thresholds.maxBlurPixels,
              quality.angularSpeed <= thresholds.maxAngularSpeed else { return .wait("blur") }
        guard quality.aimedAtObject else { return .wait("aim") }
        guard let lastShot else { return .fire }
        if now - lastShot.time < minInterval { return .wait("interval") }
        let moved = PoseMath.translationDistance(lastShot.pose, current) >= minTranslationMeters
        let turned = PoseMath.rotationAngleDegrees(lastShot.pose, current) >= minRotationDegrees
        return (moved || turned) ? .fire : .wait("move")
    }
}
