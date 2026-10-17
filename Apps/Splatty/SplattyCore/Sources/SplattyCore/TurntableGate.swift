import Foundation

/// Why a turntable shot isn't happening right now (shown big + spoken).
public enum TurntableIssue: Equatable, Hashable, Sendable {
    case tracking
    case objectOutOfView
    case wrongHeight(HeightMove)
    case tooDark
    /// The phone itself is moving; in this mode the phone should stay put.
    case phoneMoving
    /// The object is being turned faster than we can follow / shoot sharply.
    case turningTooFast
    /// A new angle is reached but the image is still moving → "停一下".
    case holdStill
}

public struct TurntableShotInput: Equatable, Sendable {
    public var activeRing: TurntableRing?
    public var elevation: Double?
    public var trackingNormal: Bool
    public var objectInView: Bool
    public var tooDark: Bool
    public var phoneAngularSpeed: Double
    public var phoneLinearSpeed: Double
    /// Estimated blur from phone motion during the exposure (pixels).
    public var phoneBlurPixels: Double
    /// Estimated blur from object rotation during the exposure (pixels).
    public var objectBlurPixels: Double
    public var turnSpeedDegreesPerSecond: Double
    /// Angle tracking is trustworthy (else fall back to `contentChanged`).
    public var rotationReliable: Bool
    /// The current progress angle falls into an uncovered bin of the active ring.
    public var inNewBin: Bool
    /// ChangeDetector: content changed enough since the last shot.
    public var contentChanged: Bool
    /// ChangeDetector: consecutive samples nearly identical.
    public var contentSteady: Bool
    public var captureInFlight: Bool
    public var now: Double
    public var lastShotTime: Double?

    public init(activeRing: TurntableRing?, elevation: Double?, trackingNormal: Bool = true, objectInView: Bool = true,
                tooDark: Bool = false, phoneAngularSpeed: Double = 0, phoneLinearSpeed: Double = 0,
                phoneBlurPixels: Double = 0, objectBlurPixels: Double = 0, turnSpeedDegreesPerSecond: Double = 0,
                rotationReliable: Bool = true, inNewBin: Bool = false, contentChanged: Bool = false,
                contentSteady: Bool = true, captureInFlight: Bool = false, now: Double, lastShotTime: Double? = nil) {
        self.activeRing = activeRing
        self.elevation = elevation
        self.trackingNormal = trackingNormal
        self.objectInView = objectInView
        self.tooDark = tooDark
        self.phoneAngularSpeed = phoneAngularSpeed
        self.phoneLinearSpeed = phoneLinearSpeed
        self.phoneBlurPixels = phoneBlurPixels
        self.objectBlurPixels = objectBlurPixels
        self.turnSpeedDegreesPerSecond = turnSpeedDegreesPerSecond
        self.rotationReliable = rotationReliable
        self.inNewBin = inNewBin
        self.contentChanged = contentChanged
        self.contentSteady = contentSteady
        self.captureInFlight = captureInFlight
        self.now = now
        self.lastShotTime = lastShotTime
    }
}

/// Auto-shutter for turntable mode: "turn a bit, stop, auto-shoot".
///
/// Fires when (a) a new angle is reached: an uncovered ~15° bin by the rotation estimate,
/// or, if the estimate is unreliable / on the top-down ring, "content changed enough
/// since the last shot"; and (b) the frame is sharp: low object flow, low phone motion.
public struct TurntableShotGate: Equatable, Sendable {
    public var plan: TurntablePlan
    public var maxPhoneAngularSpeed = 25.0   // deg/s
    public var maxPhoneLinearSpeed = 0.12    // m/s
    public var maxTurnSpeed = 45.0           // deg/s of object rotation
    public var maxBlurPixels = 2.5           // at stream resolution
    public var minInterval = 0.4             // s
    public var topMinInterval = 1.5          // s between top-down shots

    public init(plan: TurntablePlan) { self.plan = plan }

    public enum Decision: Equatable, Sendable {
        case fire
        case idle
        case rejected(TurntableIssue)
    }

    public func decide(_ i: TurntableShotInput) -> Decision {
        guard let ring = i.activeRing else { return .idle }
        if i.captureInFlight { return .idle }
        guard i.trackingNormal else { return .rejected(.tracking) }
        guard i.objectInView else { return .rejected(.objectOutOfView) }
        if let e = i.elevation, let m = plan.heightMove(for: ring, elevation: e) { return .rejected(.wrongHeight(m)) }
        if i.tooDark { return .rejected(.tooDark) }
        if i.phoneAngularSpeed > maxPhoneAngularSpeed || i.phoneLinearSpeed > maxPhoneLinearSpeed {
            return .rejected(.phoneMoving)
        }
        if ring != .top, i.rotationReliable, i.turnSpeedDegreesPerSecond > maxTurnSpeed {
            return .rejected(.turningTooFast)
        }
        if let last = i.lastShotTime {
            let gap = ring == .top ? topMinInterval : minInterval
            if i.now - last < gap { return .idle }
        }
        let newView: Bool
        if ring == .top || !i.rotationReliable {
            newView = i.contentChanged
        } else {
            newView = i.inNewBin
        }
        guard newView else { return .idle }
        let sharp = i.objectBlurPixels <= maxBlurPixels && i.phoneBlurPixels <= maxBlurPixels
            && (i.rotationReliable && ring != .top ? true : i.contentSteady)
        return sharp ? .fire : .rejected(.holdStill)
    }
}
