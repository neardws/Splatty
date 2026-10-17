import Foundation

/// What to tell the user next: which ring, raise/lower, walk left/right.
public struct GuidanceHint: Equatable, Sendable {
    public enum Vertical: Equatable, Sendable { case raise, lower }
    public enum Horizontal: Equatable, Sendable { case left, right }

    /// Ring we are guiding towards; nil when the plan is complete.
    public var activeRing: ElevationRing?
    /// Cell the camera is in right now (nil if not aimed at the object).
    public var currentCell: CoverageCell?
    /// Move the phone up/down to reach `activeRing`.
    public var vertical: Vertical?
    /// Walk left/right (from the user's point of view) to reach `targetBin`.
    public var horizontal: Horizontal?
    /// Nearest uncovered bin on `activeRing`.
    public var targetBin: Int?
    /// Unsigned azimuth distance to the target bin centre, degrees.
    public var degreesToTarget: Double?
    /// True if the current cell is an uncovered bin (a shot here is useful).
    public var currentCellIsNew: Bool

    public var isDone: Bool { activeRing == nil }
}

public struct CoverageCell: Equatable, Hashable, Sendable {
    public var ring: ElevationRing
    public var bin: Int
    public init(ring: ElevationRing, bin: Int) {
        self.ring = ring
        self.bin = bin
    }
}

public enum Guidance {
    /// Signed smallest difference `to - from` in degrees, in (-180, 180].
    public static func signedDelta(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Nearest uncovered bin on `ring` to `azimuth`; nil if the ring is full.
    public static func nearestUncoveredBin(_ coverage: CoverageMap, ring: ElevationRing, azimuth: Double)
        -> (bin: Int, delta: Double)? {
        var best: (bin: Int, delta: Double)?
        for b in 0..<coverage.bins(ring) where !coverage.isCovered(ring, bin: b) {
            let d = signedDelta(from: azimuth, to: coverage.binCenter(ring, bin: b))
            if best == nil || abs(d) < abs(best!.delta) { best = (b, d) }
        }
        return best
    }

    /// +1 if walking to the user's right increases the camera's azimuth around
    /// the anchor, -1 if it decreases it.
    public static func rightIncreasesAzimuth(cameraToWorld c2w: Mat4, anchor: Vec3) -> Bool {
        let vp = Viewpoint.of(camera: c2w.translation, anchor: anchor)
        let a = vp.azimuthDegrees * .pi / 180
        // d(position)/d(azimuth) on the horizontal circle: (cos a, 0, -sin a)
        let tangent = Vec3(cos(a), 0, -sin(a))
        let right = c2w.axis(0)
        return tangent.x * right.x + tangent.z * right.z >= 0
    }

    public static func hint(
        cameraToWorld c2w: Mat4,
        anchor: Vec3,
        coverage: CoverageMap,
        plan: CapturePlan,
        skipped: Set<ElevationRing> = []
    ) -> GuidanceHint {
        let cell = coverage.cell(cameraToWorld: c2w, anchor: anchor).map { CoverageCell(ring: $0.ring, bin: $0.bin) }
        let isNew = cell.map { !coverage.isCovered($0.ring, bin: $0.bin) && !skipped.contains($0.ring) } ?? false
        guard let active = plan.activeRing(coverage, skipped: skipped) else {
            return GuidanceHint(activeRing: nil, currentCell: cell, currentCellIsNew: isNew)
        }
        let vp = Viewpoint.of(camera: c2w.translation, anchor: anchor)
        let currentRing = coverage.ring(forElevation: vp.elevationDegrees)
        var hint = GuidanceHint(activeRing: active, currentCell: cell, currentCellIsNew: isNew)
        if currentRing != active {
            hint.vertical = active.rawValue > currentRing.rawValue ? .raise : .lower
        }
        if let target = nearestUncoveredBin(coverage, ring: active, azimuth: vp.azimuthDegrees) {
            hint.targetBin = target.bin
            hint.degreesToTarget = abs(target.delta)
            let inTarget = abs(target.delta) <= coverage.binWidth(active) / 2
            if !inTarget {
                let rightUp = rightIncreasesAzimuth(cameraToWorld: c2w, anchor: anchor)
                hint.horizontal = (target.delta > 0) == rightUp ? .right : .left
            }
        }
        return hint
    }
}

/// Auto-shutter for guided mode: shoot once per uncovered bin, never in covered bins.
public struct GuidedShotGate: Equatable, Sendable {
    public var thresholds = QualityThresholds()
    /// Minimum seconds between shots (lets the hi-res still finish).
    public var minInterval: Double = 0.3

    public init() {}

    public enum Decision: Equatable, Sendable {
        case fire
        /// Nothing useful to shoot here (covered bin, not aimed, saving...).
        case idle
        /// We'd like a shot here but the frame is bad; tell the user why.
        case rejected(CaptureWarning)
    }

    public func decide(hint: GuidanceHint, quality: FrameQualityInput, captureInFlight: Bool,
                       now: Double, lastShotTime: Double?) -> Decision {
        guard hint.currentCellIsNew else { return .idle }
        if captureInFlight { return .idle }
        if let t = lastShotTime, now - t < minInterval { return .idle }
        // Order = priority of the message shown to the user.
        let warnings = CaptureQuality.warnings(quality, thresholds: thresholds)
        for w in warnings {
            switch w {
            case .trackingLimited, .movingTooFast, .tooDark, .tooClose, .tooFar: return .rejected(w)
            case .notAimedAtObject: return .idle
            }
        }
        return .fire
    }
}
