import Foundation

/// How the user moves during a capture.
///
/// - `turntable` (default, 桌面小物件): the user stays seated with the phone roughly in
///   front and **rotates the object** (by hand or on a lazy susan). ARKit world poses are
///   NOT object poses in this mode; camera poses must be recovered on the Mac (COLMAP).
/// - `orbit` (绕拍, 大物件): the original walk-around flow; ARKit poses are valid.
public enum CaptureMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case turntable
    case orbit
    public var id: String { rawValue }

    /// Whether ARKit `camera.transform` can be used as the camera-to-object pose.
    public var arkitPosesAreObjectPoses: Bool { self == .orbit }
}

/// Phone heights in turntable mode, measured as the elevation of the phone above the
/// object centre (ARKit gives this reliably: the phone and the object centre are both
/// world-static even though the object spins in place).
public enum TurntableRing: Int, CaseIterable, Codable, Sendable {
    /// Phone roughly level with the object (10–20° above). Also accepts slightly below
    /// (low angle when the object is raised on a cup/box).
    case eye = 0
    /// Phone higher, looking down ~45°.
    case high = 1
    /// A few top-down shots.
    case top = 2

    public var key: String {
        switch self {
        case .eye: "eye"
        case .high: "high"
        case .top: "top"
        }
    }
}

/// Which way the phone should go to reach the active ring's height band.
public enum HeightMove: Equatable, Sendable {
    case raise
    case lower
}

/// Shots per ring for turntable mode.
///
/// Standard: 24 bins (15°) at eye level, 20 bins (18°) high, 3 top-down shots. A ring
/// counts as done at 92 % of its bins → 23 + 19 + 3 = 45 photos (47 max).
public struct TurntablePlan: Equatable, Sendable {
    public var eyeBins: Int
    public var highBins: Int
    public var topShots: Int
    public var requiredFraction: Double = 0.92
    public var order: [TurntableRing] = [.eye, .high, .top]
    /// Elevation bands (degrees, phone above object centre).
    public var eyeBand: ClosedRange<Double> = -35...30
    public var highBand: ClosedRange<Double> = 32...64
    public var topBand: ClosedRange<Double> = 66...90

    public init(eyeBins: Int, highBins: Int, topShots: Int) {
        precondition(eyeBins > 0 && highBins > 0 && topShots >= 0)
        self.eyeBins = eyeBins
        self.highBins = highBins
        self.topShots = topShots
    }

    public static func preset(_ p: CapturePlan.Preset) -> TurntablePlan {
        switch p {
        case .quick: TurntablePlan(eyeBins: 16, highBins: 12, topShots: 2)
        case .standard: TurntablePlan(eyeBins: 24, highBins: 20, topShots: 3)
        case .detailed: TurntablePlan(eyeBins: 36, highBins: 28, topShots: 4)
        }
    }

    public static let standard = preset(.standard)

    /// Angular bins of a ring (for `top`, the number of shots).
    public func bins(_ r: TurntableRing) -> Int {
        switch r {
        case .eye: eyeBins
        case .high: highBins
        case .top: topShots
        }
    }

    public func binWidthDegrees(_ r: TurntableRing) -> Double { 360 / Double(max(1, bins(r))) }

    /// Shots needed for the ring to count as complete.
    public func required(_ r: TurntableRing) -> Int {
        if r == .top { return topShots }
        let n = bins(r)
        return min(n, max(1, Int((Double(n) * requiredFraction).rounded(.up))))
    }

    public func targetShots(skipping skipped: Set<TurntableRing> = []) -> Int {
        order.filter { !skipped.contains($0) }.map(required).reduce(0, +)
    }

    public var maxShots: Int { order.map(bins).reduce(0, +) }

    public func band(_ r: TurntableRing) -> ClosedRange<Double> {
        switch r {
        case .eye: eyeBand
        case .high: highBand
        case .top: topBand
        }
    }

    /// Suggested elevation for the UI text.
    public func suggestedElevation(_ r: TurntableRing) -> Double {
        switch r {
        case .eye: 15
        case .high: 45
        case .top: 80
        }
    }

    /// nil when `elevation` is inside the ring's band.
    public func heightMove(for r: TurntableRing, elevation: Double) -> HeightMove? {
        let b = band(r)
        if elevation < b.lowerBound { return .raise }
        if elevation > b.upperBound { return .lower }
        return nil
    }
}

/// Coverage of the object's own rotation, per ring. Angles are "progress" angles
/// (estimated object rotation in the user's turning direction), measured from where the
/// ring started.
public struct TurntableCoverage: Equatable, Sendable {
    public let plan: TurntablePlan
    public private(set) var counts: [[Int]]
    /// Progress angle at which each ring started (nil until the ring gets its first sample).
    public private(set) var origins: [Double?]

    public init(plan: TurntablePlan) {
        self.plan = plan
        counts = TurntableRing.allCases.map { [Int](repeating: 0, count: max(1, plan.bins($0))) }
        origins = TurntableRing.allCases.map { _ in nil }
    }

    /// Sets the ring origin if not set yet.
    public mutating func begin(_ r: TurntableRing, at progressDegrees: Double) {
        if origins[r.rawValue] == nil { origins[r.rawValue] = progressDegrees }
    }

    /// Ring-relative angle in [0, 360).
    public func ringAngle(_ r: TurntableRing, progressDegrees: Double) -> Double {
        let o = origins[r.rawValue] ?? progressDegrees
        var a = (progressDegrees - o).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a
    }

    public func bin(_ r: TurntableRing, progressDegrees: Double) -> Int {
        let n = counts[r.rawValue].count
        let b = Int(ringAngle(r, progressDegrees: progressDegrees) / (360 / Double(n)))
        return min(n - 1, max(0, b))
    }

    public func isCovered(_ r: TurntableRing, bin: Int) -> Bool { counts[r.rawValue][bin] > 0 }

    /// For eye/high: records the bin of `progressDegrees`. For top: fills the next empty slot.
    @discardableResult
    public mutating func record(_ r: TurntableRing, progressDegrees: Double) -> Int {
        if r == .top {
            let slot = counts[r.rawValue].firstIndex(of: 0) ?? (counts[r.rawValue].count - 1)
            counts[r.rawValue][slot] += 1
            return slot
        }
        begin(r, at: progressDegrees)
        let b = bin(r, progressDegrees: progressDegrees)
        counts[r.rawValue][b] += 1
        return b
    }

    /// Undo a `record` (e.g. the image failed to save).
    public mutating func remove(_ r: TurntableRing, bin: Int) {
        guard counts[r.rawValue].indices.contains(bin), counts[r.rawValue][bin] > 0 else { return }
        counts[r.rawValue][bin] -= 1
    }

    public func coveredCount(_ r: TurntableRing) -> Int {
        if r == .top && plan.topShots == 0 { return 0 }
        return counts[r.rawValue].filter { $0 > 0 }.count
    }

    public func coveredBins(_ r: TurntableRing) -> [Bool] { counts[r.rawValue].map { $0 > 0 } }

    public func isComplete(_ r: TurntableRing, skipped: Set<TurntableRing> = []) -> Bool {
        skipped.contains(r) || coveredCount(r) >= plan.required(r)
    }

    /// First ring (plan order) still needing shots; nil when done.
    public func activeRing(skipping skipped: Set<TurntableRing> = []) -> TurntableRing? {
        plan.order.first { !isComplete($0, skipped: skipped) }
    }
}
