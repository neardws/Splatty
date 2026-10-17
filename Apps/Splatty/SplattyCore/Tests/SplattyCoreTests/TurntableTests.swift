import XCTest
@testable import SplattyCore

/// Camera at `position` looking at `target`, ARKit/OpenGL axes, with roll (radians) about the view axis.
func lookAt(_ position: Vec3, _ target: Vec3, roll: Double = 0) -> Mat4 {
    let back = (position - target).normalized          // camera +Z
    let worldUp = Vec3(0, 1, 0)
    var right = Vec3(worldUp.y * back.z - worldUp.z * back.y, worldUp.z * back.x - worldUp.x * back.z, worldUp.x * back.y - worldUp.y * back.x).normalized
    var up = Vec3(back.y * right.z - back.z * right.y, back.z * right.x - back.x * right.z, back.x * right.y - back.y * right.x)
    if roll != 0 {
        let r2 = right * cos(roll) + up * sin(roll)
        let u2 = up * cos(roll) - right * sin(roll)
        right = r2
        up = u2
    }
    return Mat4(rows: [
        [right.x, up.x, back.x, position.x],
        [right.y, up.y, back.y, position.y],
        [right.z, up.z, back.z, position.z],
        [0, 0, 0, 1],
    ])
}

final class TurntablePlanTests: XCTestCase {
    func testStandardBudgetIsAbout45() {
        let p = TurntablePlan.standard
        XCTAssertEqual(p.required(.eye), 23)
        XCTAssertEqual(p.required(.high), 19)
        XCTAssertEqual(p.required(.top), 3)
        XCTAssertEqual(p.targetShots(), 45)
        XCTAssertEqual(p.maxShots, 47)
        XCTAssertTrue((40...50).contains(p.targetShots()))
        XCTAssertLessThan(TurntablePlan.preset(.quick).targetShots(), p.targetShots())
        XCTAssertGreaterThan(TurntablePlan.preset(.detailed).targetShots(), p.targetShots())
        XCTAssertEqual(p.targetShots(skipping: [.top]), 42)
    }

    func testHeightMove() {
        let p = TurntablePlan.standard
        XCTAssertNil(p.heightMove(for: .eye, elevation: 15))
        XCTAssertNil(p.heightMove(for: .eye, elevation: -20), "low angle with a raised object is fine")
        XCTAssertEqual(p.heightMove(for: .eye, elevation: 50), .lower)
        XCTAssertEqual(p.heightMove(for: .high, elevation: 15), .raise)
        XCTAssertNil(p.heightMove(for: .high, elevation: 45))
        XCTAssertEqual(p.heightMove(for: .top, elevation: 45), .raise)
    }

    func testCoverageBinsRelativeToRingStartAndWrap() {
        var c = TurntableCoverage(plan: .standard)
        c.begin(.eye, at: 100)
        XCTAssertEqual(c.bin(.eye, progressDegrees: 100), 0)
        XCTAssertEqual(c.bin(.eye, progressDegrees: 116), 1)
        XCTAssertEqual(c.bin(.eye, progressDegrees: 100 + 359), 23)
        XCTAssertEqual(c.bin(.eye, progressDegrees: 100 + 361), 0, "second lap wraps")
        XCTAssertEqual(c.bin(.eye, progressDegrees: 90), 23, "turning back a bit")
    }

    func testFullTurnCompletesEyeRingThenHighThenTop() {
        var c = TurntableCoverage(plan: .standard)
        XCTAssertEqual(c.activeRing(), .eye)
        var a = 0.0
        while a < 360 { c.record(.eye, progressDegrees: a); a += 15 }
        XCTAssertEqual(c.coveredCount(.eye), 24)
        XCTAssertEqual(c.activeRing(), .high)
        for i in 0..<19 { c.record(.high, progressDegrees: 500 + Double(i) * 18) }
        XCTAssertEqual(c.activeRing(), .top)
        for _ in 0..<3 { c.record(.top, progressDegrees: 0) }
        XCTAssertNil(c.activeRing())
        XCTAssertEqual(c.activeRing(skipping: []), nil)
    }

    func testSkippingRing() {
        let c = TurntableCoverage(plan: .standard)
        XCTAssertEqual(c.activeRing(skipping: [.eye]), .high)
        XCTAssertNil(c.activeRing(skipping: [.eye, .high, .top]))
    }
}

final class TurntableGeometryTests: XCTestCase {
    let k = Intrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440)

    func testProjectCenterAndOffsets() throws {
        // Native landscape camera at the origin looking down -Z (identity pose).
        let c2w = Mat4.identity
        let p = try XCTUnwrap(TurntableGeometry.project(Vec3(0, 0, -0.5), cameraToWorld: c2w, intrinsics: k))
        XCTAssertEqual(p.x, 960, accuracy: 1e-9)
        XCTAssertEqual(p.y, 720, accuracy: 1e-9)
        let up = try XCTUnwrap(TurntableGeometry.project(Vec3(0, 0.1, -0.5), cameraToWorld: c2w, intrinsics: k))
        XCTAssertLessThan(up.y, 720, "world up is image up (smaller y) for a landscape-right camera")
        let right = try XCTUnwrap(TurntableGeometry.project(Vec3(0.1, 0, -0.5), cameraToWorld: c2w, intrinsics: k))
        XCTAssertEqual(right.x, 960 + 1400 * 0.2, accuracy: 1e-9)
        XCTAssertNil(TurntableGeometry.project(Vec3(0, 0, 0.5), cameraToWorld: c2w, intrinsics: k))
    }

    func testProjectFromLookAt() throws {
        let target = Vec3(0.2, 0.0, -0.3)
        let c2w = lookAt(Vec3(0.2, 0.1, 0.1), target)
        let p = try XCTUnwrap(TurntableGeometry.project(target, cameraToWorld: c2w, intrinsics: k))
        XCTAssertEqual(p.x, 960, accuracy: 1e-6)
        XCTAssertEqual(p.y, 720, accuracy: 1e-6)
    }

    func testHorizontalAxisAndUprightRotationForEachGrip() throws {
        let target = Vec3(0, 0, -0.4)
        let eye = Vec3(0, 0.08, 0)
        // roll 0: sensor-native landscape (home button right) → image already upright.
        let native = lookAt(eye, target)
        XCTAssertEqual(TurntableGeometry.uprightRotationCW(native), 0)
        let axis = try XCTUnwrap(TurntableGeometry.horizontalAxis(native))
        XCTAssertEqual(axis.x, 1, accuracy: 1e-6)
        XCTAssertEqual(axis.y, 0, accuracy: 1e-6)
        // Portrait: camera +X points down the device (towards Home), i.e. world down.
        let portrait = lookAt(eye, target, roll: -.pi / 2)
        let g = TurntableGeometry.gravityUpInCamera(portrait)
        XCTAssertEqual(g.x, -1, accuracy: 0.05, "portrait: up = -X (towards the front camera)")
        XCTAssertEqual(TurntableGeometry.uprightRotationCW(portrait), 90, "portrait frames need 90° CW, like UIImage .right")
        let pAxis = try XCTUnwrap(TurntableGeometry.horizontalAxis(portrait))
        XCTAssertEqual(abs(pAxis.y), 1, accuracy: 1e-3, "surface motion is along the sensor's short side in portrait")
        let upside = lookAt(eye, target, roll: .pi)
        XCTAssertEqual(TurntableGeometry.uprightRotationCW(upside), 180)
        let portraitDown = lookAt(eye, target, roll: .pi / 2)
        XCTAssertEqual(TurntableGeometry.uprightRotationCW(portraitDown), 270, "upside-down portrait (scooping)")
    }

    func testTopDownHasNoHorizontalAxis() {
        let c2w = lookAt(Vec3(0, 0.4, 0.001), Vec3(0, 0, 0))
        XCTAssertNil(TurntableGeometry.horizontalAxis(c2w))
        XCTAssertGreaterThan(TurntableGeometry.elevationDegrees(camera: c2w, objectCenter: .zero), 80)
    }

    func testApparentRadius() {
        let box = PixelRect(minX: 0, minY: 0, maxX: 400, maxY: 200)
        XCTAssertEqual(TurntableGeometry.apparentRadius(box: box, axis: Vec2(1, 0)), 200)
        XCTAssertEqual(TurntableGeometry.apparentRadius(box: box, axis: Vec2(0, -1)), 100)
        XCTAssertEqual(TurntableGeometry.assumedRadiusPixels(objectRadiusMeters: 0.05, distance: 0.35, focal: 1400), 200, accuracy: 1e-9)
    }
}

final class RotationTrackerTests: XCTestCase {
    /// Simulates registration of a cylinder of apparent radius R turning `step`° per sample,
    /// with whole-pixel shifts against a keyframe, like Vision returns.
    func simulate(totalDegrees: Double, step: Double, radius: Double, axis: Vec2 = Vec2(1, 0), sign: Double = 1,
                  under: Double = 1.0) -> RotationTracker {
        var t = RotationTracker()
        var trueAngle = 0.0, keyAngle = 0.0, time = 0.0
        while trueAngle < totalDegrees - 1e-9 {
            trueAngle += step
            time += 0.1
            let px = ((trueAngle - keyAngle) * .pi / 180 * radius * under).rounded() * sign
            let out = t.ingest(.init(shift: axis * px, axis: axis, radiusPixels: radius, timestamp: time))
            if out.rekey { keyAngle = trueAngle }
        }
        return t
    }

    func testAccumulatesFullTurnWithinFewDegrees() {
        let t = simulate(totalDegrees: 360, step: 1.5, radius: 300)
        XCTAssertEqual(t.progressDegrees, 360, accuracy: 6)
        XCTAssertEqual(t.speedDegreesPerSecond, 15, accuracy: 2)
        XCTAssertTrue(t.isReliable)
    }

    func testDirectionLockMakesProgressPositive() {
        let t = simulate(totalDegrees: 90, step: 2, radius: 300, sign: -1)
        XCTAssertEqual(t.direction, -1)
        XCTAssertEqual(t.progressDegrees, 90, accuracy: 3)
    }

    func testUnderestimatingRegistrationIsConservative() {
        let t = simulate(totalDegrees: 360, step: 2, radius: 300, under: 0.8)
        XCTAssertLessThan(t.progressDegrees, 360, "estimate must not exceed the true angle")
    }

    func testPortraitAxis() {
        let t = simulate(totalDegrees: 180, step: 2, radius: 250, axis: Vec2(0, -1))
        XCTAssertEqual(t.progressDegrees, 180, accuracy: 4)
    }

    func testCrossMotionAndPhoneMotionAreRejected() {
        var t = RotationTracker()
        var out = t.ingest(.init(shift: Vec2(2, 30), axis: Vec2(1, 0), radiusPixels: 300, timestamp: 0.1))
        XCTAssertFalse(out.accepted)
        XCTAssertTrue(out.rekey)
        out = t.ingest(.init(shift: Vec2(20, 0), axis: Vec2(1, 0), radiusPixels: 300, timestamp: 0.2, phoneSteady: false))
        XCTAssertFalse(out.accepted)
        XCTAssertEqual(t.signedDegrees, 0)
        for i in 0..<10 { _ = t.ingest(.init(shift: nil, axis: Vec2(1, 0), radiusPixels: 300, timestamp: 0.3 + Double(i) * 0.1)) }
        XCTAssertFalse(t.isReliable)
        _ = t.ingest(.init(shift: Vec2(5, 0), axis: Vec2(1, 0), radiusPixels: 300, timestamp: 2))
        XCTAssertTrue(t.isReliable)
    }

    func testRekeyEveryFewDegrees() {
        var t = RotationTracker()
        let out = t.ingest(.init(shift: Vec2(50, 0), axis: Vec2(1, 0), radiusPixels: 300, timestamp: 0.1))
        XCTAssertTrue(out.rekey)
        XCTAssertEqual(t.signedDegrees, 50.0 / 300 * 180 / .pi, accuracy: 1e-9)
        let out2 = t.ingest(.init(shift: Vec2(5, 0), axis: Vec2(1, 0), radiusPixels: 300, timestamp: 0.2))
        XCTAssertFalse(out2.rekey)
        XCTAssertEqual(t.signedDegrees, 55.0 / 300 * 180 / .pi, accuracy: 1e-9)
    }
}

final class ChangeDetectorTests: XCTestCase {
    func testChangedAndSteady() {
        var d = ChangeDetector()
        let a = [UInt8](repeating: 100, count: 256)
        let b = [UInt8](repeating: 130, count: 256)
        d.ingest(a)
        XCTAssertTrue(d.changedEnough, "no shot yet")
        XCTAssertFalse(d.isSteady)
        d.ingest(a)
        XCTAssertTrue(d.isSteady)
        d.markShot()
        d.ingest(a)
        XCTAssertFalse(d.changedEnough)
        d.ingest(b)
        XCTAssertTrue(d.changedEnough)
        XCTAssertFalse(d.isSteady)
        d.ingest(b)
        XCTAssertTrue(d.isSteady)
        XCTAssertEqual(ChangeDetector.meanAbsDiff(a, b), 30)
        XCTAssertEqual(ChangeDetector.meanAbsDiff(a, []), .infinity)
    }
}

final class TurntableGateTests: XCTestCase {
    let gate = TurntableShotGate(plan: .standard)

    func good(_ ring: TurntableRing = .eye, now: Double = 10) -> TurntableShotInput {
        TurntableShotInput(activeRing: ring, elevation: ring == .eye ? 15 : (ring == .high ? 45 : 80),
                           turnSpeedDegreesPerSecond: 5, rotationReliable: true, inNewBin: true,
                           contentChanged: true, contentSteady: true, now: now, lastShotTime: 9)
    }

    func testFiresOnNewBinWhenSteady() {
        XCTAssertEqual(gate.decide(good()), .fire)
    }

    func testIdleWhenBinCovered() {
        var i = good()
        i.inNewBin = false
        XCTAssertEqual(gate.decide(i), .idle)
    }

    func testHoldStillWhenBlurry() {
        var i = good()
        i.objectBlurPixels = 6
        XCTAssertEqual(gate.decide(i), .rejected(.holdStill))
    }

    func testTooFastAndPhoneMoving() {
        var i = good()
        i.turnSpeedDegreesPerSecond = 80
        XCTAssertEqual(gate.decide(i), .rejected(.turningTooFast))
        i = good()
        i.phoneAngularSpeed = 60
        XCTAssertEqual(gate.decide(i), .rejected(.phoneMoving))
    }

    func testWrongHeight() {
        var i = good(.high)
        i.elevation = 10
        XCTAssertEqual(gate.decide(i), .rejected(.wrongHeight(.raise)))
    }

    func testFallbackUsesContentChange() {
        var i = good()
        i.rotationReliable = false
        i.inNewBin = false
        i.contentChanged = true
        i.contentSteady = false
        XCTAssertEqual(gate.decide(i), .rejected(.holdStill))
        i.contentSteady = true
        XCTAssertEqual(gate.decide(i), .fire)
        i.contentChanged = false
        XCTAssertEqual(gate.decide(i), .idle)
    }

    func testTopRingUsesContentChangeAndLongerInterval() {
        var i = good(.top)
        i.inNewBin = false
        i.lastShotTime = 9.5
        XCTAssertEqual(gate.decide(i), .idle, "top shots need ≥ 1.5 s between them")
        i.lastShotTime = 8
        XCTAssertEqual(gate.decide(i), .fire)
    }

    func testIdleWhileSavingOrDone() {
        var i = good()
        i.captureInFlight = true
        XCTAssertEqual(gate.decide(i), .idle)
        i = good()
        i.activeRing = nil
        XCTAssertEqual(gate.decide(i), .idle)
    }

    /// End-to-end: a simulated "turn, stop, shoot" session of one eye ring.
    func testSimulatedEyeRingTakesAboutOneShotPerBin() {
        var cov = TurntableCoverage(plan: .standard)
        var tracker = RotationTracker()
        var shots = 0, lastShot: Double?
        var trueAngle = 0.0, keyAngle = 0.0, time = 0.0
        let radius = 280.0
        cov.begin(.eye, at: 0)
        // Turn at 20°/s for 0.5 s, pause 0.5 s, repeat — until the ring completes.
        while cov.activeRing() == .eye, time < 120 {
            time += 0.1
            let phase = time.truncatingRemainder(dividingBy: 1.0)
            let turning = phase < 0.5
            if turning { trueAngle += 2 }
            let px = ((trueAngle - keyAngle) * .pi / 180 * radius).rounded()
            if tracker.ingest(.init(shift: Vec2(px, 0), axis: Vec2(1, 0), radiusPixels: radius, timestamp: time)).rekey {
                keyAngle = trueAngle
            }
            let p = tracker.progressDegrees
            let bin = cov.bin(.eye, progressDegrees: p)
            let input = TurntableShotInput(
                activeRing: .eye, elevation: 15,
                objectBlurPixels: turning ? 20 * .pi / 180 * radius / 60 : 0,
                turnSpeedDegreesPerSecond: tracker.speedDegreesPerSecond,
                rotationReliable: tracker.isReliable, inNewBin: !cov.isCovered(.eye, bin: bin),
                now: time, lastShotTime: lastShot)
            if gate.decide(input) == .fire {
                cov.record(.eye, progressDegrees: p)
                shots += 1
                lastShot = time
            }
        }
        XCTAssertNotEqual(cov.activeRing(), .eye)
        XCTAssertGreaterThanOrEqual(shots, 23)
        XCTAssertLessThanOrEqual(shots, 24)
        XCTAssertGreaterThanOrEqual(trueAngle, 320)
        XCTAssertLessThan(time, 40, "a ring should take well under a minute")
    }
}

final class CoachAndOrientationTests: XCTestCase {
    func testCoachRateLimitsAndNudges() {
        var c = TurntableCoach()
        XCTAssertEqual(c.cue(for: .turningTooFast, now: 0, capturing: true), .tooFast)
        XCTAssertNil(c.cue(for: .turningTooFast, now: 1, capturing: true), "global gap")
        XCTAssertNil(c.cue(for: .turningTooFast, now: 3, capturing: true), "per-cue cooldown")
        XCTAssertEqual(c.cue(for: .holdStill, now: 3, capturing: true), .holdStill)
        XCTAssertEqual(c.cue(for: .turningTooFast, now: 6, capturing: true), .tooFast)
        XCTAssertEqual(c.say(.ringDone(next: .high), now: 6.1), .ringDone(next: .high), "milestones always play")
        c.noteProgress(7)
        XCTAssertNil(c.cue(for: nil, now: 9, capturing: true))
        XCTAssertEqual(c.cue(for: nil, now: 11.5, capturing: true), .keepTurning)
        XCTAssertNil(c.cue(for: .tooDark, now: 20, capturing: false))
    }

    func testOrientationResolverWithHysteresis() {
        var r = UIRotationResolver()
        let target = Vec3(0, 0, -0.4), eye = Vec3(0, 0.08, 0)
        XCTAssertEqual(r.update(upInCamera: TurntableGeometry.gravityUpInCamera(lookAt(eye, target, roll: -.pi / 2))), 0, "portrait")
        // Native landscape (home right, top left): device right edge points up → rotate UI 90° CW.
        XCTAssertEqual(r.update(upInCamera: TurntableGeometry.gravityUpInCamera(lookAt(eye, target))), 90)
        XCTAssertEqual(r.orientationName, "landscape_top_left")
        XCTAssertEqual(r.update(upInCamera: TurntableGeometry.gravityUpInCamera(lookAt(eye, target, roll: .pi / 2))), 180)
        XCTAssertEqual(r.update(upInCamera: TurntableGeometry.gravityUpInCamera(lookAt(eye, target, roll: .pi))), -90)
        // 50° from portrait-upside-down… still between quadrants → keep current.
        var r2 = UIRotationResolver()
        r2.update(upInCamera: Vec3(-1, 0, 0))
        XCTAssertEqual(r2.degrees, 0)
        let a = 50 * Double.pi / 180
        r2.update(upInCamera: Vec3(-cos(a), sin(a), 0))
        XCTAssertEqual(r2.degrees, 0, "hysteresis")
        // Flat phone: ignored.
        r2.update(upInCamera: Vec3(0.1, 0.1, 0.99))
        XCTAssertEqual(r2.degrees, 0)
    }
}

final class TurntableSerializationTests: XCTestCase {
    func frame(_ i: Int) -> FrameRecord {
        var f = FrameRecord(index: i, filePath: AssetLayout.relativeImagePath(index: i, ext: "jpg"),
                            transform: Mat4.rigid(rotation: Mat4.rotationY(0.2), translation: Vec3(0, 0.1, 0.3)),
                            intrinsics: Intrinsics(fx: 2800, fy: 2800, cx: 2016, cy: 1512, width: 4032, height: 3024),
                            timestamp: 10, capturedAt: "2026-10-17T20:00:00+08:00", exposureDuration: 1.0 / 60,
                            exposureOffset: 0, tracking: "normal", highResolution: true)
        f.poseValid = false
        f.maskFilePath = AssetLayout.relativeMaskPath(index: i, imageExt: "jpg")
        f.uprightRotationCW = 90
        f.deviceOrientation = "portrait"
        f.gravityCamera = [-1, 0, 0]
        f.objectRotationDegrees = 15
        f.elevationDegrees = 14
        f.turntableRing = "eye"
        return f
    }

    func testTurntableTransformsHaveNoTransformMatrix() throws {
        let doc = try XCTUnwrap(TransformsDocument.make(frames: [frame(1)], captureMode: .turntable,
                                                        maskSource: MaskInfo.visionPreliminary))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["splatty_capture_mode"] as? String, "turntable")
        XCTAssertEqual(obj["splatty_poses_valid"] as? Bool, false)
        XCTAssertEqual(obj["splatty_pose_source"] as? String, "none_needs_sfm")
        XCTAssertEqual(obj["splatty_mask_source"] as? String, "vision_preliminary")
        XCTAssertEqual(obj["fl_x"] as? Double, 2800)
        XCTAssertNil(obj["ply_file_path"])
        let f = try XCTUnwrap((obj["frames"] as? [[String: Any]])?.first)
        XCTAssertNil(f["transform_matrix"], "no fake object poses")
        XCTAssertNotNil(f["device_transform_matrix"])
        XCTAssertEqual(f["pose_valid"] as? Bool, false)
        XCTAssertEqual(f["mask_path"] as? String, "masks/frame_00001.jpg.png")
        XCTAssertEqual(f["upright_rotation_cw"] as? Int, 90)
        XCTAssertEqual(f["turntable_ring"] as? String, "eye")
        let back = try TransformsDocument.decode(doc.jsonData())
        XCTAssertEqual(back, doc)
    }

    func testOrbitDocumentStillHasPoses() throws {
        var f = frame(1)
        f.poseValid = true
        let doc = try XCTUnwrap(TransformsDocument.make(frames: [f]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["splatty_capture_mode"] as? String, "orbit")
        XCTAssertEqual(obj["splatty_poses_valid"] as? Bool, true)
        let fr = try XCTUnwrap((obj["frames"] as? [[String: Any]])?.first)
        XCTAssertNotNil(fr["transform_matrix"])
        XCTAssertNil(fr["pose_valid"])
    }

    func testMetaV2RoundTripAndV1Compat() throws {
        var m = AssetMeta(id: "x", folder: "f", name: "n", category: .figure, createdAt: "c", timeZone: "Asia/Shanghai")
        m.captureMode = .turntable
        m.posesValid = false
        m.masks = MaskInfo(count: 3)
        let back = try AssetMeta.decode(m.jsonData())
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.schemaVersion, 2)
        let v1 = #"{"schemaVersion":1,"id":"a","folder":"b","name":"c","category":"toy","createdAt":"d","timeZone":"e","status":"draft","counts":{"images":0,"depth":0},"notes":""}"#
        let old = try AssetMeta.decode(Data(v1.utf8))
        XCTAssertNil(old.captureMode)
    }
}

final class NonFiniteEncodingTests: XCTestCase {
    func testNaNLightEstimateAndExposureDoNotBreakTransforms() throws {
        var f = FrameRecord(index: 1, filePath: "raw/frame_00001.jpg", transform: .identity,
                            intrinsics: Intrinsics(fx: 1400, fy: 1400, cx: 960, cy: 720, width: 1920, height: 1440),
                            timestamp: 1, capturedAt: "t", exposureDuration: .nan, exposureOffset: .infinity,
                            ambientIntensity: .nan, ambientColorTemperature: -.infinity, tracking: "normal",
                            highResolution: true, depthTimestamp: .nan)
        f.gravityCamera = [.nan, 1, 0]
        f.elevationDegrees = .nan
        var bad = f
        bad.index = 2
        bad.transform[0, 3] = .nan
        let doc = try XCTUnwrap(TransformsDocument.make(frames: [f, bad], objectAnchor: Vec3(.nan, 0, 0)))
        XCTAssertEqual(doc.frames.count, 1, "frames with non-finite poses are skipped")
        let data = try doc.jsonData()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fr = try XCTUnwrap((obj["frames"] as? [[String: Any]])?.first)
        XCTAssertEqual(fr["exposure_duration"] as? Double, 0)
        XCTAssertEqual(fr["exposure_offset"] as? Double, 0)
        XCTAssertNil(fr["ambient_intensity"])
        XCTAssertNil(fr["ambient_color_temperature"])
        XCTAssertNil(fr["gravity_camera"])
        XCTAssertNil(fr["elevation_deg"])
        XCTAssertNil(obj["splatty_object_anchor"])
    }

    func testAllFramesBadGivesNil() {
        var f = FrameRecord(index: 1, filePath: "raw/a.jpg", transform: .identity,
                            intrinsics: Intrinsics(fx: .nan, fy: 1, cx: 1, cy: 1, width: 2, height: 2),
                            timestamp: 0, capturedAt: "t", exposureDuration: 0, exposureOffset: 0,
                            tracking: "normal", highResolution: false)
        XCTAssertNil(TransformsDocument.make(frames: [f]))
        f.intrinsics.fx = 1
        XCTAssertNotNil(TransformsDocument.make(frames: [f]))
    }
}

final class CaptureLogTests: XCTestCase {
    func testFoldsRepeatsAndCountsRejections() throws {
        var log = CaptureLog(captureMode: "turntable", startedAt: "t0")
        log.add("rejected", "holdStill", t: 1)
        log.add("rejected", "holdStill", t: 1.1)
        log.add("shot", "frame 1", t: 1.5)
        log.add("rejected", "holdStill", t: 2)
        log.add("error", "x", t: .nan)
        XCTAssertEqual(log.entries.count, 4)
        XCTAssertEqual(log.entries[0].count, 2)
        XCTAssertEqual(log.rejectionTotals["holdStill"], 3)
        XCTAssertNoThrow(try log.jsonData())
    }
}
