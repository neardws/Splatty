import XCTest
@testable import SplattyCore

final class CaptureQualityTests: XCTestCase {
    let good = FrameQualityInput(tracking: .normal, ambientIntensity: 1000, exposureDuration: 1.0 / 120,
                                 estimatedBlurPixels: 0.5, angularSpeed: 5, aimedAtObject: true)

    func testNoWarningsWhenGood() {
        XCTAssertEqual(CaptureQuality.warnings(good), [])
    }

    func testWarnings() {
        var i = good
        i.tracking = .limited(reason: "excessiveMotion")
        i.ambientIntensity = 100
        i.estimatedBlurPixels = 10
        i.aimedAtObject = false
        XCTAssertEqual(CaptureQuality.warnings(i), [.trackingLimited("excessiveMotion"), .tooDark, .movingTooFast, .notAimedAtObject])
        var j = good
        j.exposureDuration = 1.0 / 15
        XCTAssertEqual(CaptureQuality.warnings(j), [.tooDark])
    }

    func testBlurModel() {
        // 30°/s, 1/60 s, f=1500 px → 0.5236 rad/s * 0.01667 * 1500 ≈ 13.1 px
        let b = BlurModel.estimatedBlurPixels(angularSpeedDegPerSec: 30, linearSpeed: 0, exposureDuration: 1.0 / 60,
                                              focalLengthPixels: 1500, objectDistance: 0.3)
        XCTAssertEqual(b, 30 * .pi / 180 / 60 * 1500, accuracy: 1e-9)
        let t = BlurModel.estimatedBlurPixels(angularSpeedDegPerSec: 0, linearSpeed: 0.1, exposureDuration: 0.01,
                                              focalLengthPixels: 1500, objectDistance: 0.5)
        XCTAssertEqual(t, 0.1 * 0.01 / 0.5 * 1500, accuracy: 1e-9)
    }

    func testMotionEstimator() {
        var m = MotionEstimator(smoothing: 1)
        m.update(pose: .identity, timestamp: 0)
        m.update(pose: Mat4.rigid(rotation: Mat4.rotationY(.pi / 180), translation: Vec3(0.01, 0, 0)), timestamp: 0.1)
        XCTAssertEqual(m.linearSpeed, 0.1, accuracy: 1e-9)
        XCTAssertEqual(m.angularSpeed, 10, accuracy: 1e-6)
    }

    func testAutoGate() {
        let gate = AutoCaptureGate()
        let p0 = Mat4.identity
        XCTAssertEqual(gate.decide(current: p0, now: 0, lastShot: nil, quality: good, captureInFlight: false), .fire)
        XCTAssertEqual(gate.decide(current: p0, now: 0, lastShot: nil, quality: good, captureInFlight: true), .wait("saving"))
        // Too soon / not moved
        XCTAssertEqual(gate.decide(current: p0, now: 1, lastShot: (p0, 0), quality: good, captureInFlight: false), .wait("move"))
        XCTAssertEqual(gate.decide(current: p0, now: 0.1, lastShot: (p0, 0), quality: good, captureInFlight: false), .wait("interval"))
        // Rotated 6°
        let rot = Mat4.rigid(rotation: Mat4.rotationY(6 * .pi / 180), translation: .zero)
        XCTAssertEqual(gate.decide(current: rot, now: 1, lastShot: (p0, 0), quality: good, captureInFlight: false), .fire)
        // Moved 4 cm
        let mv = Mat4.rigid(rotation: Mat4.identity.rotation, translation: Vec3(0.04, 0, 0))
        XCTAssertEqual(gate.decide(current: mv, now: 1, lastShot: (p0, 0), quality: good, captureInFlight: false), .fire)
        // Blurry / tracking
        var blurry = good; blurry.estimatedBlurPixels = 9
        XCTAssertEqual(gate.decide(current: rot, now: 1, lastShot: (p0, 0), quality: blurry, captureInFlight: false), .wait("blur"))
        var limited = good; limited.tracking = .limited(reason: "initializing")
        XCTAssertEqual(gate.decide(current: rot, now: 1, lastShot: (p0, 0), quality: limited, captureInFlight: false), .wait("tracking"))
    }
}
