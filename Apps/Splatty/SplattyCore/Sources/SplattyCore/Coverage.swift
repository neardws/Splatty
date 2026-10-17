import Foundation

/// Elevation ring of a viewpoint around the object.
public enum ElevationRing: Int, CaseIterable, Sendable, Codable {
    case low = 0
    case mid = 1
    case high = 2

    public var label: String {
        switch self {
        case .low: "Low"
        case .mid: "Mid"
        case .high: "High"
        }
    }
}

/// Where a camera sits relative to the object anchor.
public struct Viewpoint: Equatable, Sendable {
    /// Degrees in [0, 360). 0 = world +Z side of the anchor, increasing towards +X.
    public var azimuthDegrees: Double
    /// Degrees in [-90, 90]. Positive = camera above the anchor.
    public var elevationDegrees: Double
    /// Camera-to-anchor distance in metres.
    public var distance: Double

    public init(azimuthDegrees: Double, elevationDegrees: Double, distance: Double) {
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.distance = distance
    }

    /// Viewpoint of `camera` (world position) around `anchor` (world position),
    /// using ARKit's Y-up world frame.
    public static func of(camera: Vec3, anchor: Vec3) -> Viewpoint {
        let v = camera - anchor
        let horizontal = (v.x * v.x + v.z * v.z).squareRoot()
        var az = atan2(v.x, v.z) * 180 / .pi
        if az < 0 { az += 360 }
        if az >= 360 { az -= 360 }
        let el = atan2(v.y, horizontal) * 180 / .pi
        return Viewpoint(azimuthDegrees: az, elevationDegrees: el, distance: v.length)
    }
}

/// Coverage histogram: 3 elevation rings, each with its own number of azimuth bins.
public struct CoverageMap: Equatable, Sendable {
    /// Azimuth bins per ring, indexed by `ElevationRing.rawValue`.
    public let binCounts: [Int]
    /// Upper elevation bound (degrees, exclusive) of the low ring.
    public let lowMaxElevation: Double
    /// Upper elevation bound (degrees, exclusive) of the mid ring.
    public let midMaxElevation: Double
    /// Only count shots whose view direction is within this angle of the anchor.
    public let maxOffAxisDegrees: Double
    public private(set) var counts: [[Int]]

    /// Same number of bins on every ring.
    public init(
        binsPerRing: Int = 24,
        lowMaxElevation: Double = 15,
        midMaxElevation: Double = 40,
        maxOffAxisDegrees: Double = 35
    ) {
        self.init(binCounts: [binsPerRing, binsPerRing, binsPerRing], lowMaxElevation: lowMaxElevation,
                  midMaxElevation: midMaxElevation, maxOffAxisDegrees: maxOffAxisDegrees)
    }

    public init(binCounts: [Int], lowMaxElevation: Double = 15, midMaxElevation: Double = 40, maxOffAxisDegrees: Double = 35) {
        precondition(binCounts.count == ElevationRing.allCases.count && binCounts.allSatisfy { $0 > 0 })
        self.binCounts = binCounts
        self.lowMaxElevation = lowMaxElevation
        self.midMaxElevation = midMaxElevation
        self.maxOffAxisDegrees = maxOffAxisDegrees
        counts = binCounts.map { Array(repeating: 0, count: $0) }
    }

    /// Coverage map shaped by a capture plan.
    public init(plan: CapturePlan) {
        self.init(binCounts: ElevationRing.allCases.map { plan.spec($0).bins },
                  lowMaxElevation: plan.lowMaxElevation, midMaxElevation: plan.midMaxElevation,
                  maxOffAxisDegrees: plan.maxOffAxisDegrees)
    }

    public func bins(_ ring: ElevationRing) -> Int { binCounts[ring.rawValue] }

    /// Angular width (degrees) of one bin in `ring`.
    public func binWidth(_ ring: ElevationRing) -> Double { 360 / Double(bins(ring)) }

    /// Centre azimuth (degrees) of `bin` in `ring`.
    public func binCenter(_ ring: ElevationRing, bin: Int) -> Double { (Double(bin) + 0.5) * binWidth(ring) }

    public func ring(forElevation e: Double) -> ElevationRing {
        if e < lowMaxElevation { return .low }
        if e < midMaxElevation { return .mid }
        return .high
    }

    public func bin(forAzimuth a: Double, ring: ElevationRing = .mid) -> Int {
        let n = bins(ring)
        var az = a.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        let b = Int(az / 360 * Double(n))
        return min(max(b, 0), n - 1)
    }

    public func cell(for vp: Viewpoint) -> (ring: ElevationRing, bin: Int) {
        let r = ring(forElevation: vp.elevationDegrees)
        return (r, bin(forAzimuth: vp.azimuthDegrees, ring: r))
    }

    /// Cell for a camera pose, or nil if the camera isn't looking at the anchor.
    public func cell(cameraToWorld c2w: Mat4, anchor: Vec3) -> (ring: ElevationRing, bin: Int)? {
        guard PoseMath.offAxisAngleDegrees(c2w, target: anchor) <= maxOffAxisDegrees else { return nil }
        return cell(for: .of(camera: c2w.translation, anchor: anchor))
    }

    /// Record a shot. Returns the cell it landed in (nil = not aimed at the anchor).
    @discardableResult
    public mutating func record(cameraToWorld c2w: Mat4, anchor: Vec3) -> (ring: ElevationRing, bin: Int)? {
        guard let c = cell(cameraToWorld: c2w, anchor: anchor) else { return nil }
        counts[c.ring.rawValue][c.bin] += 1
        return c
    }

    public mutating func reset() {
        counts = binCounts.map { Array(repeating: 0, count: $0) }
    }

    public func isCovered(_ ring: ElevationRing, bin: Int) -> Bool { counts[ring.rawValue][bin] > 0 }

    public func coveredCount(_ ring: ElevationRing) -> Int { counts[ring.rawValue].filter { $0 > 0 }.count }

    /// Fraction of azimuth bins in `ring` with at least one shot.
    public func fraction(_ ring: ElevationRing) -> Double {
        Double(coveredCount(ring)) / Double(bins(ring))
    }

    /// Mean coverage over all rings.
    public var overallFraction: Double {
        ElevationRing.allCases.map(fraction).reduce(0, +) / Double(ElevationRing.allCases.count)
    }
}
