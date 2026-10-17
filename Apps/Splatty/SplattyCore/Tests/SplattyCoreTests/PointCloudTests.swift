import XCTest
@testable import SplattyCore

final class PointCloudTests: XCTestCase {
    func testVoxelDedup() {
        var acc = PointCloudAccumulator(voxelSize: 0.01, maxPoints: 3)
        XCTAssertTrue(acc.add(ColoredPoint(Vec3(0.001, 0.001, 0.001))))
        XCTAssertFalse(acc.add(ColoredPoint(Vec3(0.009, 0.002, 0.003)))) // same voxel
        XCTAssertTrue(acc.add(ColoredPoint(Vec3(0.011, 0, 0))))
        XCTAssertFalse(acc.add(ColoredPoint(Vec3(.nan, 0, 0))))
        XCTAssertTrue(acc.add(ColoredPoint(Vec3(-0.001, 0, 0)))) // negative side is a different voxel
        XCTAssertFalse(acc.add(ColoredPoint(Vec3(5, 5, 5)))) // cap reached
        XCTAssertEqual(acc.count, 3)
    }

    func testPLYBinaryLayout() throws {
        let pts = [ColoredPoint(Vec3(1, 2, 3), r: 10, g: 20, b: 30), ColoredPoint(Vec3(-1, 0.5, 0))]
        let data = PLYWriter.binary(pts)
        let text = String(decoding: data.prefix(400), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        XCTAssertTrue(text.contains("element vertex 2\n"))
        let headerEnd = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        let body = data[headerEnd.upperBound...]
        XCTAssertEqual(body.count, 2 * 15)
        let b = Array(body)
        let x = Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        XCTAssertEqual(x, 1)
        XCTAssertEqual(Array(b[12..<15]), [10, 20, 30])
    }

    func testUnprojectionCentreRayIdentityPose() {
        let k = Intrinsics(fx: 200, fy: 200, cx: 128, cy: 96, width: 256, height: 192)
        // Pixel whose centre is the principal point: (127.5+0.5 = 128, 95.5+0.5 = 96) → u=127.5 isn't integral,
        // so use the analytic offset instead.
        let p = DepthUnprojection.worldPoint(u: 127, v: 95, depth: 0.5, intrinsics: k, cameraToWorld: .identity)
        XCTAssertEqual(p.z, -0.5, accuracy: 1e-12)              // in front of camera = -Z
        XCTAssertEqual(p.x, (127.5 - 128) / 200 * 0.5, accuracy: 1e-12)
        XCTAssertEqual(p.y, -(95.5 - 96) / 200 * 0.5, accuracy: 1e-12) // image up = +Y
        // Pixel in the top-left quadrant maps to -X, +Y
        let q = DepthUnprojection.worldPoint(u: 0, v: 0, depth: 1, intrinsics: k, cameraToWorld: .identity)
        XCTAssertLessThan(q.x, 0)
        XCTAssertGreaterThan(q.y, 0)
    }

    func testUnprojectionWithPose() {
        let k = Intrinsics(fx: 100, fy: 100, cx: 50, cy: 50, width: 100, height: 100)
        // Camera at (0,0,1) rotated 90° about Y: looks down world -X.
        let c2w = Mat4.rigid(rotation: Mat4.rotationY(.pi / 2), translation: Vec3(0, 0, 1))
        let p = DepthUnprojection.worldPoint(u: 49, v: 49, depth: 2, intrinsics: k, cameraToWorld: c2w)
        XCTAssertEqual(p.x, -2, accuracy: 0.02)
        XCTAssertEqual(p.z, 1, accuracy: 0.02)
    }

    func testDepthSamplerFiltersConfidenceAndRange() {
        let w = 16, h = 16
        var depth = [Float](repeating: 0.5, count: w * h)
        var conf = [UInt8](repeating: 2, count: w * h)
        depth[4 * w + 4] = 3.0   // too far
        conf[4 * w + 12] = 1     // low confidence
        let k = Intrinsics(fx: 20, fy: 20, cx: 8, cy: 8, width: w, height: h)
        let s = DepthSampler.samples(depth: depth, confidence: conf, width: w, height: h, stride: 8,
                                     intrinsics: k, cameraToWorld: .identity)
        // grid: (4,4) (12,4) (4,12) (12,12) → two rejected
        XCTAssertEqual(s.map { [$0.u, $0.v] }, [[4, 12], [12, 12]])
        XCTAssertEqual(s[0].world.z, -0.5, accuracy: 1e-9)
    }

    func testYCbCr() {
        XCTAssertTrue(ColorConversion.rgb(y: 128, cb: 128, cr: 128) == (128, 128, 128))
        XCTAssertTrue(ColorConversion.rgb(y: 255, cb: 128, cr: 128) == (255, 255, 255))
        let red = ColorConversion.rgb(y: 76, cb: 85, cr: 255)
        XCTAssertGreaterThan(red.0, 240)
        XCTAssertLessThan(red.1, 10)
    }
}
