import XCTest
@testable import SplattyCore

final class PoseMathTests: XCTestCase {
    func testColumnMajorInitTransposes() {
        // Columns: X, Y, Z axes then translation (1,2,3).
        let m = Mat4(columns: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [1, 2, 3, 1]])
        XCTAssertEqual(m.translation, Vec3(1, 2, 3))
        XCTAssertEqual(m.m[0], [1, 0, 0, 1])
        XCTAssertEqual(m.m[3], [0, 0, 0, 1])
    }

    func testRotationAngle() {
        let a = Mat4.identity
        let b = Mat4.rigid(rotation: Mat4.rotationY(10 * .pi / 180), translation: .zero)
        XCTAssertEqual(PoseMath.rotationAngleDegrees(a, b), 10, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.rotationAngleDegrees(b, b), 0, accuracy: 1e-6)
    }

    func testTranslationDistance() {
        let a = Mat4.rigid(rotation: Mat4.identity.rotation, translation: Vec3(0, 0, 0))
        let b = Mat4.rigid(rotation: Mat4.identity.rotation, translation: Vec3(0.03, 0.04, 0))
        XCTAssertEqual(PoseMath.translationDistance(a, b), 0.05, accuracy: 1e-12)
    }

    func testForwardIsMinusZ() {
        XCTAssertEqual(PoseMath.forward(.identity), Vec3(0, 0, -1))
        let p = PoseMath.point(inFrontOf: .identity, distance: 0.3)
        XCTAssertEqual(p.z, -0.3, accuracy: 1e-12)
    }

    func testOffAxis() {
        XCTAssertEqual(PoseMath.offAxisAngleDegrees(.identity, target: Vec3(0, 0, -1)), 0, accuracy: 1e-9)
        XCTAssertEqual(PoseMath.offAxisAngleDegrees(.identity, target: Vec3(1, 0, 0)), 90, accuracy: 1e-9)
    }

    func testOpenCVConversionFlipsYAndZAxes() {
        let c2w = Mat4.rigid(rotation: Mat4.rotationY(0.3), translation: Vec3(1, 2, 3))
        let cv = CameraConvention.arkitToOpenCV(c2w)
        XCTAssertEqual(cv.translation, c2w.translation)
        XCTAssertEqual(cv.axis(0), c2w.axis(0))
        XCTAssertEqual(cv.axis(1), -c2w.axis(1))
        XCTAssertEqual(cv.axis(2), -c2w.axis(2))
        XCTAssertEqual(CameraConvention.arkitToNerfstudio(c2w), c2w)
    }

    func testIntrinsicsScaling() {
        let k = Intrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
        let s = k.scaled(toWidth: 3840, height: 2880)
        XCTAssertEqual(s.fx, 3000)
        XCTAssertEqual(s.cy, 1440)
        XCTAssertEqual(s.width, 3840)
        XCTAssertEqual(k.scaled(toWidth: 1920, height: 1440), k)
    }
}
