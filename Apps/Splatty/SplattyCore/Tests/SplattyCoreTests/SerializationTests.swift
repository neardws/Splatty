import XCTest
@testable import SplattyCore

final class SerializationTests: XCTestCase {
    func sampleFrame(_ i: Int, depth: Bool) -> FrameRecord {
        FrameRecord(
            index: i,
            filePath: AssetLayout.relativeImagePath(index: i, ext: "jpg"),
            depthFilePath: depth ? AssetLayout.relativeDepthPath(index: i) : nil,
            confidenceFilePath: depth ? AssetLayout.relativeConfidencePath(index: i) : nil,
            transform: Mat4.rigid(rotation: Mat4.rotationY(0.1 * Double(i)), translation: Vec3(0.1, 0.2, 0.3)),
            intrinsics: Intrinsics(fx: 1500.5, fy: 1500.5, cx: 959.5, cy: 719.5, width: 1920, height: 1440),
            timestamp: 1234.5 + Double(i),
            capturedAt: "2026-10-17T16:00:00+08:00",
            exposureDuration: 1.0 / 60,
            exposureOffset: 0,
            ambientIntensity: 900,
            tracking: "normal",
            highResolution: false,
            ring: 1,
            azimuthBin: 3
        )
    }

    func testTransformsJSONHasNerfstudioKeys() throws {
        let doc = try XCTUnwrap(TransformsDocument.make(frames: [sampleFrame(1, depth: true), sampleFrame(2, depth: false)],
                                                        objectAnchor: Vec3(0, 0, -0.3),
                                                        plyFilePath: AssetLayout.relativePointsPath))
        let data = try doc.jsonData()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["camera_model", "fl_x", "fl_y", "cx", "cy", "w", "h", "frames"] {
            XCTAssertNotNil(obj[key], key)
        }
        XCTAssertEqual(obj["w"] as? Int, 1920)
        XCTAssertEqual(obj["depth_unit_scale_factor"] as? Double, 0.001)
        XCTAssertEqual(obj["ply_file_path"] as? String, "arkit/points3D.ply")
        let frames = try XCTUnwrap(obj["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["file_path"] as? String, "raw/frame_00001.jpg")
        XCTAssertEqual(frames[0]["depth_file_path"] as? String, "depth/frame_00001.png")
        XCTAssertNil(frames[1]["depth_file_path"])
        let tm = try XCTUnwrap(frames[0]["transform_matrix"] as? [[Double]])
        XCTAssertEqual(tm.count, 4)
        XCTAssertEqual(tm[0][3], 0.1, accuracy: 1e-12)
        XCTAssertEqual(tm[3], [0, 0, 0, 1])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\\/"))
        // msplat treats paths starting with "." as CWD-relative; we must never emit them.
        for f in frames { XCTAssertFalse((f["file_path"] as? String ?? ".").hasPrefix(".")) }
    }

    func testTransformsRoundTrip() throws {
        let doc = try XCTUnwrap(TransformsDocument.make(frames: [sampleFrame(1, depth: true)]))
        let back = try TransformsDocument.decode(doc.jsonData())
        XCTAssertEqual(back, doc)
    }

    func testMakeEmptyIsNil() {
        XCTAssertNil(TransformsDocument.make(frames: []))
    }

    func testMetaRoundTrip() throws {
        var meta = AssetMeta(id: "abc234", folder: "20261017_pikachu_abc234", name: "Pikachu", category: .figure,
                             createdAt: "2026-10-17T16:00:00+08:00", timeZone: "Asia/Shanghai")
        meta.status = .captured
        meta.counts = AssetCounts(images: 120, depth: 120)
        meta.device = DeviceInfo(model: "iPhone", identifier: "iPhone18,1", systemVersion: "26.0", hasLiDAR: true)
        let data = try meta.jsonData()
        XCTAssertEqual(try AssetMeta.decode(data), meta)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "captured")
        XCTAssertEqual(obj["category"] as? String, "figure")
    }

    func testDepthEncoding() {
        let mm = DepthEncoding.millimeters(fromMeters: [0.25, 0, -1, .nan, .infinity, 70, 0.0004, 1.2345])
        XCTAssertEqual(mm, [250, 0, 0, 0, 0, 65535, 0, 1235])
    }
}
