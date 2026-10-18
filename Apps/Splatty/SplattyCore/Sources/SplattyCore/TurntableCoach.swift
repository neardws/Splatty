import Foundation

/// Spoken / haptic cues for when the user can't see the screen.
public enum CoachCue: Equatable, Hashable, Sendable {
    case start(TurntableRing)
    case keepTurning
    case holdStill
    case tooFast
    case phoneMoving
    case raisePhone
    case lowerPhone
    case objectOutOfView
    case tooDark
    case ringDone(next: TurntableRing)
    case allDone(shots: Int)
    case switchedToSimpleMode

    /// Ring/finish cues always play; others are rate-limited.
    public var isMilestone: Bool {
        switch self {
        case .start, .ringDone, .allDone, .switchedToSimpleMode: true
        default: false
        }
    }
}

/// Decides which cue to say, without nagging: a global gap between cues, a longer
/// per-cue cooldown, and a "keep turning" nudge after a few idle seconds.
public struct TurntableCoach: Sendable {
    public var minGap = 1.8
    public var repeatCooldown = 5.0
    public var idleNudgeAfter = 4.0

    private var lastSpoken: [CoachCue: Double] = [:]
    private var lastAny: Double = -.infinity
    /// Time of last progress (shot or ring start); drives the idle nudge.
    public private(set) var lastProgress: Double?

    public init() {}

    /// Note progress (a shot, a ring start) so we don't nudge right after.
    public mutating func noteProgress(_ now: Double) { lastProgress = now }

    /// Returns `cue` if it should be spoken now, recording it.
    public mutating func say(_ cue: CoachCue, now: Double) -> CoachCue? {
        if !cue.isMilestone {
            if now - lastAny < minGap { return nil }
            if let t = lastSpoken[cue], now - t < repeatCooldown { return nil }
        }
        lastSpoken[cue] = now
        lastAny = now
        return cue
    }

    /// Cue for the current gate outcome; nil = stay quiet.
    public mutating func cue(for issue: TurntableIssue?, now: Double, capturing: Bool) -> CoachCue? {
        guard capturing else { return nil }
        if let issue {
            let c: CoachCue? = switch issue {
            case .tracking: nil
            case .objectOutOfView: .objectOutOfView
            case .wrongHeight(.raise): .raisePhone
            case .wrongHeight(.lower): .lowerPhone
            case .tooDark: .tooDark
            case .phoneMoving: .phoneMoving
            case .turningTooFast: .tooFast
            case .holdStill: .holdStill
            }
            if let c { return say(c, now: now) }
            return nil
        }
        if let p = lastProgress, now - p >= idleNudgeAfter {
            lastProgress = now
            return say(.keepTurning, now: now)
        }
        if lastProgress == nil { lastProgress = now }
        return nil
    }
}

/// Keeps overlay text readable whatever way the phone is held (portrait, landscape,
/// upside-down for "scooping" low shots), using gravity from ARKit instead of
/// UIDevice orientation (which stalls when the phone is near flat).
public struct UIRotationResolver: Sendable, Equatable {
    /// Clockwise rotation (degrees) to apply to portrait-locked UI: 0, 90, 180 or -90.
    public private(set) var degrees: Int = 0
    /// Must be this close (degrees) to a new quadrant's centre to switch (hysteresis).
    public var switchWithin = 30.0
    /// Ignore when the phone is nearly flat (gravity mostly along the camera axis).
    public var minTilt = 0.45

    public init() {}

    /// `upInCamera`: world up in ARKit camera axes (`TurntableGeometry.gravityUpInCamera`).
    @discardableResult
    public mutating func update(upInCamera u: Vec3) -> Int {
        // Portrait-screen axes: D_right = camera +Y, D_up = camera -X.
        let right = u.y, up = -u.x
        guard (right * right + up * up).squareRoot() >= minTilt else { return degrees }
        let theta = atan2(right, up) * 180 / .pi
        var candidate = Int((theta / 90).rounded()) * 90
        if candidate == -180 { candidate = 180 }
        if candidate == 270 { candidate = -90 }
        guard candidate != degrees else { return degrees }
        var diff = abs(theta - Double(candidate)).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff = 360 - diff }
        if diff <= switchWithin { degrees = candidate }
        return degrees
    }

    /// Name stored in exports.
    public var orientationName: String {
        switch degrees {
        case 0: "portrait"
        case 90: "landscape_top_left"
        case -90: "landscape_top_right"
        default: "portrait_upside_down"
        }
    }
}
