import Foundation

/// How many views to take on each elevation ring, and in which order to guide the user.
///
/// Default ("standard"): mid ring 24 bins (15°), high and low 12 bins (30°) each;
/// a ring counts as done at 90 % of its bins → about 44 photos, 48 max.
public struct CapturePlan: Equatable, Sendable {
    public struct RingSpec: Equatable, Sendable {
        public var ring: ElevationRing
        public var bins: Int
        /// Elevation (degrees) we suggest holding the phone at, for the UI.
        public var suggestedElevation: Double
        public init(ring: ElevationRing, bins: Int, suggestedElevation: Double) {
            self.ring = ring
            self.bins = bins
            self.suggestedElevation = suggestedElevation
        }
    }

    public var rings: [RingSpec]
    /// Guidance order (default mid → high → low).
    public var order: [ElevationRing]
    /// Fraction of a ring's bins needed for it to count as complete.
    public var requiredFraction: Double
    public var lowMaxElevation: Double = 15
    public var midMaxElevation: Double = 40
    public var maxOffAxisDegrees: Double = 35

    public init(rings: [RingSpec], order: [ElevationRing] = [.mid, .high, .low], requiredFraction: Double = 0.9) {
        precondition(Set(rings.map(\.ring)) == Set(ElevationRing.allCases), "plan needs one spec per ring")
        self.rings = rings
        self.order = order
        self.requiredFraction = requiredFraction
    }

    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        case quick, standard, detailed
        public var id: String { rawValue }
    }

    public static func preset(_ p: Preset) -> CapturePlan {
        switch p {
        case .quick: make(mid: 16, other: 8)
        case .standard: make(mid: 24, other: 12)
        case .detailed: make(mid: 36, other: 18)
        }
    }

    public static let standard = preset(.standard)

    static func make(mid: Int, other: Int) -> CapturePlan {
        CapturePlan(rings: [
            RingSpec(ring: .low, bins: other, suggestedElevation: 5),
            RingSpec(ring: .mid, bins: mid, suggestedElevation: 25),
            RingSpec(ring: .high, bins: other, suggestedElevation: 55),
        ])
    }

    public func spec(_ ring: ElevationRing) -> RingSpec { rings.first { $0.ring == ring }! }

    /// Bins needed for `ring` to be complete.
    public func required(_ ring: ElevationRing) -> Int {
        let n = spec(ring).bins
        return min(n, max(1, Int((Double(n) * requiredFraction).rounded(.up))))
    }

    /// Sum of `required` over non-skipped rings (the "target" photo count shown to the user).
    public func targetShots(skipping skipped: Set<ElevationRing> = []) -> Int {
        order.filter { !skipped.contains($0) }.map(required).reduce(0, +)
    }

    /// Maximum photos if every bin were filled.
    public var maxShots: Int { rings.map(\.bins).reduce(0, +) }
}

/// Per-ring progress for a coverage map under a plan.
public struct RingProgress: Equatable, Sendable {
    public var ring: ElevationRing
    public var covered: Int
    public var required: Int
    public var total: Int
    public var skipped: Bool
    public var isComplete: Bool { skipped || covered >= required }
}

public extension CapturePlan {
    func progress(_ coverage: CoverageMap, skipped: Set<ElevationRing> = []) -> [RingProgress] {
        order.map { r in
            RingProgress(ring: r, covered: coverage.coveredCount(r), required: required(r),
                         total: coverage.bins(r), skipped: skipped.contains(r))
        }
    }

    /// First ring (in guidance order) that still needs photos; nil when everything is done.
    func activeRing(_ coverage: CoverageMap, skipped: Set<ElevationRing> = []) -> ElevationRing? {
        progress(coverage, skipped: skipped).first { !$0.isComplete }?.ring
    }

    func isComplete(_ coverage: CoverageMap, skipped: Set<ElevationRing> = []) -> Bool {
        activeRing(coverage, skipped: skipped) == nil
    }
}
