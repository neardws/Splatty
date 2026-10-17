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

/// Coverage histogram: 3 elevation rings × N azimuth bins.
public struct CoverageMap: Equatable, Sendable {
    public let binsPerRing: Int
    /// Upper elevation bound (degrees, exclusive) of the low ring.
    public let lowMaxElevation: Double
    /// Upper elevation bound (degrees, exclusive) of the mid ring.
    public let midMaxElevation: Double
    /// Only count shots whose view direction is within this angle of the anchor.
    public let maxOffAxisDegrees: Double
    public private(set) var counts: [[Int]]

    public init(
        binsPerRing: Int = 24,
        lowMaxElevation: Double = 15,
        midMaxElevation: Double = 40,
        maxOffAxisDegrees: Double = 35
    ) {
        precondition(binsPerRing > 0)
        self.binsPerRing = binsPerRing
        self.lowMaxElevation = lowMaxElevation
        self.midMaxElevation = midMaxElevation
        self.maxOffAxisDegrees = maxOffAxisDegrees
        counts = Array(repeating: Array(repeating: 0, count: binsPerRing), count: ElevationRing.allCases.count)
    }

    public func ring(forElevation e: Double) -> ElevationRing {
        if e < lowMaxElevation { return .low }
        if e < midMaxElevation { return .mid }
        return .high
    }

    public func bin(forAzimuth a: Double) -> Int {
        var az = a.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        let b = Int(az / 360 * Double(binsPerRing))
        return min(max(b, 0), binsPerRing - 1)
    }

    public func cell(for vp: Viewpoint) -> (ring: ElevationRing, bin: Int) {
        (ring(forElevation: vp.elevationDegrees), bin(forAzimuth: vp.azimuthDegrees))
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
        counts = Array(repeating: Array(repeating: 0, count: binsPerRing), count: ElevationRing.allCases.count)
    }

    public func isCovered(_ ring: ElevationRing, bin: Int) -> Bool { counts[ring.rawValue][bin] > 0 }

    /// Fraction of azimuth bins in `ring` with at least one shot.
    public func fraction(_ ring: ElevationRing) -> Double {
        let row = counts[ring.rawValue]
        return Double(row.filter { $0 > 0 }.count) / Double(binsPerRing)
    }

    /// Mean coverage over all rings.
    public var overallFraction: Double {
        ElevationRing.allCases.map(fraction).reduce(0, +) / Double(ElevationRing.allCases.count)
    }
}
