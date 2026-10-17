import Foundation

/// Estimates how far the object has turned, from image registration only (no markers).
///
/// The app crops a window centred on the projected object centre (so small phone motion
/// is compensated by re-centring), and registers the current crop against a keyframe crop
/// (translation only, e.g. Vision `VNTranslationalImageRegistrationRequest`). For an
/// object spinning about the vertical axis, its visible surface slides sideways in the
/// image by roughly ω·R_pix, where R_pix is the object's apparent radius. So
///
///     Δθ ≈ (shift along the image-horizontal axis) / R_pix
///
/// independent of distance and focal length. Registration over the whole object (whose
/// edges move slower than its front, plus some static background) under-estimates the
/// shift, so this estimate is **conservative**: the user turns a bit more than 360° per
/// ring, which only adds overlap.
///
/// Keyframing: registration returns whole pixels, so we register against a keyframe and
/// re-key every `rekeyDegrees` instead of integrating tiny frame-to-frame shifts.
public struct RotationTracker: Sendable {
    public struct Sample: Equatable, Sendable {
        /// Shift of the current crop's content relative to the keyframe crop, full-res pixels (x right, y down).
        public var shift: Vec2?
        /// Unit image-horizontal axis (see `TurntableGeometry.horizontalAxis`); nil = unknown.
        public var axis: Vec2?
        /// Apparent object radius along `axis`, full-res pixels.
        public var radiusPixels: Double
        public var timestamp: Double
        /// False while the phone itself is moving a lot (we don't trust the shift then).
        public var phoneSteady: Bool

        public init(shift: Vec2?, axis: Vec2?, radiusPixels: Double, timestamp: Double, phoneSteady: Bool = true) {
            self.shift = shift
            self.axis = axis
            self.radiusPixels = radiusPixels
            self.timestamp = timestamp
            self.phoneSteady = phoneSteady
        }
    }

    public struct Output: Equatable, Sendable {
        /// The app should make the current crop the new keyframe.
        public var rekey: Bool
        /// The sample was used to update the angle.
        public var accepted: Bool
    }

    public var rekeyDegrees = 8.0
    /// Reject samples whose cross-axis shift is much larger than the along-axis shift
    /// (hand in the frame, phone tilting, object toppled...).
    public var maxCrossRatio = 1.5
    public var minCrossPixels = 4.0
    /// Consecutive bad samples after which `isReliable` turns false.
    public var unreliableAfter = 8
    /// EMA factor for speed.
    public var smoothing = 0.35
    /// |progress| at which the turning direction gets locked.
    public var directionLockDegrees = 10.0

    /// Signed accumulated angle (degrees), sign follows the image axis.
    public private(set) var signedDegrees: Double = 0
    /// +1 / -1 once the user's turning direction is known.
    public private(set) var direction: Double?
    /// Smoothed absolute turning speed (deg/s).
    public private(set) var speedDegreesPerSecond: Double = 0
    /// Last radius used (pixels), for converting speed to image flow.
    public private(set) var lastRadiusPixels: Double = 0
    public private(set) var consecutiveFailures = 0
    public private(set) var acceptedSamples = 0
    private var keyDegrees: Double = 0
    private var last: (degrees: Double, time: Double)?

    public init() {}

    /// Estimated object rotation in the user's turning direction (monotone-ish increasing).
    public var progressDegrees: Double { signedDegrees * (direction ?? 1) }

    public var isReliable: Bool { consecutiveFailures < unreliableAfter }

    /// Image flow speed of the object's front surface (pixels/s) at the current turning speed.
    public var flowPixelsPerSecond: Double { speedDegreesPerSecond * .pi / 180 * lastRadiusPixels }

    public mutating func ingest(_ s: Sample) -> Output {
        guard s.phoneSteady, let shift = s.shift, let axis = s.axis, s.radiusPixels > 1 else {
            fail(s.timestamp)
            return Output(rekey: true, accepted: false)
        }
        let along = shift.dot(axis)
        let cross = shift.x * -axis.y + shift.y * axis.x
        if abs(cross) > max(minCrossPixels, maxCrossRatio * abs(along)) {
            fail(s.timestamp)
            return Output(rekey: true, accepted: false)
        }
        consecutiveFailures = 0
        acceptedSamples += 1
        lastRadiusPixels = s.radiusPixels
        let sinceKey = along / s.radiusPixels * 180 / .pi
        signedDegrees = keyDegrees + sinceKey
        if direction == nil, abs(signedDegrees) >= directionLockDegrees {
            direction = signedDegrees > 0 ? 1 : -1
        }
        updateSpeed(s.timestamp)
        var rekey = false
        if abs(sinceKey) >= rekeyDegrees {
            keyDegrees = signedDegrees
            rekey = true
        }
        return Output(rekey: rekey, accepted: true)
    }

    /// Call after the app made a new keyframe for reasons of its own (crop size change...).
    public mutating func didRekey() { keyDegrees = signedDegrees }

    private mutating func fail(_ t: Double) {
        consecutiveFailures += 1
        keyDegrees = signedDegrees
        // Decay the speed so a stale "too fast" doesn't stick.
        speedDegreesPerSecond *= (1 - smoothing)
        last = (signedDegrees, t)
    }

    private mutating func updateSpeed(_ t: Double) {
        defer { last = (signedDegrees, t) }
        guard let last else { return }
        let dt = t - last.time
        guard dt > 1e-3, dt < 2 else { return }
        let v = abs(signedDegrees - last.degrees) / dt
        speedDegreesPerSecond += smoothing * (v - speedDegreesPerSecond)
    }
}

/// Fallback trigger when the angle can't be estimated (textureless/symmetric object,
/// top-down shots): compares small grayscale thumbnails of the object crop.
public struct ChangeDetector: Sendable, Equatable {
    /// Mean absolute difference (0–255) vs the last shot needed to call it "new content".
    public var changedThreshold = 14.0
    /// Mean absolute difference vs the previous sample below which the view is "steady".
    public var steadyThreshold = 4.0

    public private(set) var lastShot: [UInt8]?
    public private(set) var previous: [UInt8]?
    public private(set) var changeSinceShot: Double = 0
    public private(set) var changeSincePrevious: Double = .infinity

    public init() {}

    public static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s = 0
        for i in a.indices { s += abs(Int(a[i]) - Int(b[i])) }
        return Double(s) / Double(a.count)
    }

    public mutating func ingest(_ thumb: [UInt8]) {
        changeSincePrevious = previous.map { Self.meanAbsDiff($0, thumb) } ?? .infinity
        changeSinceShot = lastShot.map { Self.meanAbsDiff($0, thumb) } ?? .infinity
        previous = thumb
    }

    public var isSteady: Bool { changeSincePrevious <= steadyThreshold }
    /// Content changed enough since the last shot (or no shot yet).
    public var changedEnough: Bool { changeSinceShot >= changedThreshold }

    public mutating func markShot() {
        lastShot = previous
        changeSinceShot = 0
    }

    public mutating func reset() {
        lastShot = nil
        previous = nil
        changeSinceShot = 0
        changeSincePrevious = .infinity
    }
}
