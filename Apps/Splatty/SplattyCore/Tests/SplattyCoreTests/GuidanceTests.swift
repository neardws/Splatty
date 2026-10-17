import XCTest
@testable import SplattyCore

final class CapturePlanTests: XCTestCase {
    func testStandardPlanCounts() {
        let p = CapturePlan.standard
        XCTAssertEqual(p.spec(.mid).bins, 24)
        XCTAssertEqual(p.required(.mid), 22)   // ceil(24 * 0.9)
        XCTAssertEqual(p.required(.high), 11)  // ceil(12 * 0.9)
        XCTAssertEqual(p.targetShots(), 44)
        XCTAssertEqual(p.targetShots(skipping: [.low]), 33)
        XCTAssertEqual(p.maxShots, 48)
        XCTAssertEqual(CapturePlan.preset(.quick).targetShots(), 15 + 8 + 8)
        XCTAssertEqual(CapturePlan.preset(.detailed).maxShots, 72)
    }

    func testActiveRingOrderAndSkip() {
        let plan = CapturePlan.standard
        var map = CoverageMap(plan: plan)
        XCTAssertEqual(plan.activeRing(map), .mid)
        for b in 0..<22 { map.record(cameraToWorld: orbitPose(azimuth: map.binCenter(.mid, bin: b), elevation: 25), anchor: .zero) }
        XCTAssertEqual(plan.activeRing(map), .high)
        XCTAssertEqual(plan.activeRing(map, skipped: [.high]), .low)
        XCTAssertNil(plan.activeRing(map, skipped: [.high, .low]))
        XCTAssertTrue(plan.isComplete(map, skipped: [.high, .low]))
        let prog = plan.progress(map)
        XCTAssertEqual(prog.map(\.ring), [.mid, .high, .low])
        XCTAssertEqual(prog[0].covered, 22)
        XCTAssertTrue(prog[0].isComplete)
        XCTAssertFalse(prog[1].isComplete)
    }
}

final class GuidanceTests: XCTestCase {
    let plan = CapturePlan.standard

    func testSignedDelta() {
        XCTAssertEqual(Guidance.signedDelta(from: 350, to: 10), 20)
        XCTAssertEqual(Guidance.signedDelta(from: 10, to: 350), -20)
        XCTAssertEqual(Guidance.signedDelta(from: 0, to: 180), 180)
    }

    func testRightIncreasesAzimuthForLookAtCamera() {
        for az in stride(from: 0.0, to: 360, by: 45) {
            XCTAssertTrue(Guidance.rightIncreasesAzimuth(cameraToWorld: orbitPose(azimuth: az, elevation: 20), anchor: .zero), "az \(az)")
        }
        // Rolled upside down (camera right points the other way) flips it.
        let flipped = orbitPose(azimuth: 0, elevation: 0) * Mat4.rigid(rotation: [[-1, 0, 0], [0, -1, 0], [0, 0, 1]], translation: .zero)
        XCTAssertFalse(Guidance.rightIncreasesAzimuth(cameraToWorld: flipped, anchor: .zero))
    }

    func testFreshStartInTargetBin() {
        let map = CoverageMap(plan: plan)
        let h = Guidance.hint(cameraToWorld: orbitPose(azimuth: 7, elevation: 25), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(h.activeRing, .mid)
        XCTAssertNil(h.vertical)
        XCTAssertNil(h.horizontal)          // already in an uncovered bin
        XCTAssertEqual(h.targetBin, 0)
        XCTAssertTrue(h.currentCellIsNew)
        XCTAssertEqual(h.currentCell, CoverageCell(ring: .mid, bin: 0))
    }

    func testPointsToNearestUncoveredBinAndNeverCovered() {
        var map = CoverageMap(plan: plan)
        for b in 0...4 { map.record(cameraToWorld: orbitPose(azimuth: map.binCenter(.mid, bin: b), elevation: 25), anchor: .zero) }
        // Standing in covered bin 0: nearest uncovered is bin 23 (−15°) → walk left.
        let h = Guidance.hint(cameraToWorld: orbitPose(azimuth: 7.5, elevation: 25), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(h.targetBin, 23)
        XCTAssertEqual(h.degreesToTarget ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(h.horizontal, .left)
        XCTAssertFalse(h.currentCellIsNew)
        // Standing in bin 3: bin 5 is +30°, bin 23 is −60° → walk right.
        let h2 = Guidance.hint(cameraToWorld: orbitPose(azimuth: 52, elevation: 25), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(h2.targetBin, 5)
        XCTAssertEqual(h2.horizontal, .right)
    }

    func testRaiseAndLower() {
        var map = CoverageMap(plan: plan)
        let low = Guidance.hint(cameraToWorld: orbitPose(azimuth: 0, elevation: 5), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(low.vertical, .raise)
        let high = Guidance.hint(cameraToWorld: orbitPose(azimuth: 0, elevation: 60), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(high.vertical, .lower)
        // Finish mid → active becomes high; from mid elevation we must raise.
        for b in 0..<24 { map.record(cameraToWorld: orbitPose(azimuth: map.binCenter(.mid, bin: b), elevation: 25), anchor: .zero) }
        let next = Guidance.hint(cameraToWorld: orbitPose(azimuth: 0, elevation: 25), anchor: .zero, coverage: map, plan: plan)
        XCTAssertEqual(next.activeRing, .high)
        XCTAssertEqual(next.vertical, .raise)
    }

    func testDone() {
        var map = CoverageMap(plan: plan)
        for r in ElevationRing.allCases {
            let el = plan.spec(r).suggestedElevation
            for b in 0..<map.bins(r) { map.record(cameraToWorld: orbitPose(azimuth: map.binCenter(r, bin: b), elevation: el), anchor: .zero) }
        }
        let h = Guidance.hint(cameraToWorld: orbitPose(azimuth: 0, elevation: 25), anchor: .zero, coverage: map, plan: plan)
        XCTAssertTrue(h.isDone)
        XCTAssertFalse(h.currentCellIsNew)
    }
}

final class GuidedShotGateTests: XCTestCase {
    let good = FrameQualityInput(tracking: .normal, ambientIntensity: 1000, exposureDuration: 1.0 / 120,
                                 estimatedBlurPixels: 0.5, angularSpeed: 5, aimedAtObject: true, distance: 0.3)
    let plan = CapturePlan.standard

    func hint(newCell: Bool) -> GuidanceHint {
        GuidanceHint(activeRing: .mid, currentCell: CoverageCell(ring: .mid, bin: 0), currentCellIsNew: newCell)
    }

    func testFiresOnlyInNewBins() {
        let gate = GuidedShotGate()
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: good, captureInFlight: false, now: 1, lastShotTime: nil), .fire)
        XCTAssertEqual(gate.decide(hint: hint(newCell: false), quality: good, captureInFlight: false, now: 1, lastShotTime: nil), .idle)
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: good, captureInFlight: true, now: 1, lastShotTime: nil), .idle)
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: good, captureInFlight: false, now: 1, lastShotTime: 0.9), .idle)
    }

    func testRejectsWithReason() {
        let gate = GuidedShotGate()
        var q = good
        q.estimatedBlurPixels = 20
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: q, captureInFlight: false, now: 1, lastShotTime: nil), .rejected(.movingTooFast))
        q = good; q.tracking = .limited(reason: "low texture")
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: q, captureInFlight: false, now: 1, lastShotTime: nil), .rejected(.trackingLimited("low texture")))
        q = good; q.ambientIntensity = 50
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: q, captureInFlight: false, now: 1, lastShotTime: nil), .rejected(.tooDark))
        q = good; q.distance = 0.05
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: q, captureInFlight: false, now: 1, lastShotTime: nil), .rejected(.tooClose))
        q = good; q.distance = 2
        XCTAssertEqual(gate.decide(hint: hint(newCell: true), quality: q, captureInFlight: false, now: 1, lastShotTime: nil), .rejected(.tooFar))
    }

    /// Simulated slow orbit: one shot per mid bin, no duplicates.
    func testSimulatedOrbitTakesOneShotPerBin() {
        let gate = GuidedShotGate()
        var map = CoverageMap(plan: plan)
        var shots = 0
        var t = 0.0
        for step in 0..<720 { // 0.5° steps, 2 laps
            t += 0.05
            let pose = orbitPose(azimuth: Double(step) * 0.5, elevation: 25)
            let h = Guidance.hint(cameraToWorld: pose, anchor: .zero, coverage: map, plan: plan)
            if gate.decide(hint: h, quality: good, captureInFlight: false, now: t, lastShotTime: nil) == .fire {
                map.record(cameraToWorld: pose, anchor: .zero)
                shots += 1
            }
        }
        XCTAssertEqual(shots, 24)
        XCTAssertEqual(map.coveredCount(.mid), 24)
        XCTAssertEqual(map.counts[ElevationRing.mid.rawValue].max(), 1)
    }
}
