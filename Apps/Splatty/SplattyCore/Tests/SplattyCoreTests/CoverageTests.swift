import XCTest
@testable import SplattyCore

final class CoverageTests: XCTestCase {
    /// Camera on a circle of `radius` at azimuth/elevation (deg), looking at the origin.
    func lookAtPose(azimuth: Double, elevation: Double, radius: Double = 0.3) -> Mat4 {
        let az = azimuth * .pi / 180, el = elevation * .pi / 180
        // Camera +Z (back) points from the anchor to the camera.
        let r = Mat4.matmul3(Mat4.rotationY(az), Mat4.rotationX(-el))
        let back = Vec3(r[0][2], r[1][2], r[2][2])
        return Mat4.rigid(rotation: r, translation: back * radius)
    }

    func testViewpointMath() {
        let vp = Viewpoint.of(camera: Vec3(0, 0, 1), anchor: .zero)
        XCTAssertEqual(vp.azimuthDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(vp.elevationDegrees, 0, accuracy: 1e-9)
        let vp2 = Viewpoint.of(camera: Vec3(-1, 1, 0), anchor: .zero)
        XCTAssertEqual(vp2.azimuthDegrees, 270, accuracy: 1e-9)
        XCTAssertEqual(vp2.elevationDegrees, 45, accuracy: 1e-9)
    }

    func testRingBoundaries() {
        let map = CoverageMap()
        XCTAssertEqual(map.ring(forElevation: -20), .low)
        XCTAssertEqual(map.ring(forElevation: 14.9), .low)
        XCTAssertEqual(map.ring(forElevation: 15), .mid)
        XCTAssertEqual(map.ring(forElevation: 39.9), .mid)
        XCTAssertEqual(map.ring(forElevation: 60), .high)
    }

    func testAzimuthBins() {
        let map = CoverageMap(binsPerRing: 24)
        XCTAssertEqual(map.bin(forAzimuth: 0), 0)
        XCTAssertEqual(map.bin(forAzimuth: 14.99), 0)
        XCTAssertEqual(map.bin(forAzimuth: 15), 1)
        XCTAssertEqual(map.bin(forAzimuth: 359.9), 23)
        XCTAssertEqual(map.bin(forAzimuth: -1), 23)
        XCTAssertEqual(map.bin(forAzimuth: 360), 0)
    }

    func testFullOrbitCoversRing() {
        var map = CoverageMap(binsPerRing: 24)
        for i in 0..<24 {
            let cell = map.record(cameraToWorld: lookAtPose(azimuth: Double(i) * 15 + 7, elevation: 25), anchor: .zero)
            XCTAssertEqual(cell?.ring, .mid)
            XCTAssertEqual(cell?.bin, i)
        }
        XCTAssertEqual(map.fraction(.mid), 1, accuracy: 1e-12)
        XCTAssertEqual(map.fraction(.low), 0)
        XCTAssertEqual(map.overallFraction, 1.0 / 3, accuracy: 1e-12)
    }

    func testShotNotAimedAtAnchorIsIgnored() {
        var map = CoverageMap()
        // Looking away: camera at +Z of anchor but facing +Z (away).
        let away = Mat4.rigid(rotation: Mat4.rotationY(.pi), translation: Vec3(0, 0, 0.3))
        XCTAssertNil(map.record(cameraToWorld: away, anchor: .zero))
        XCTAssertEqual(map.overallFraction, 0)
    }
}
