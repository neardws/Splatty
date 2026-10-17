import XCTest
@testable import SplattyCore

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class NamingTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(AssetNaming.slug("Pikachu (Gold Ver.)"), "pikachu-gold-ver")
        XCTAssertEqual(AssetNaming.slug("  --Hello__World--  "), "hello-world")
        XCTAssertEqual(AssetNaming.slug("Café Ünïcode"), "cafe-unicode")
        XCTAssertEqual(AssetNaming.slug("!!!", fallback: "badge"), "badge")
        XCTAssertEqual(AssetNaming.slug(String(repeating: "ab ", count: 30)).count <= 32, true)
        XCTAssertFalse(AssetNaming.slug(String(repeating: "ab ", count: 30)).hasSuffix("-"))
    }

    func testSlugNonLatin() {
        let s = AssetNaming.slug("皮卡丘", fallback: "figure")
        #if canImport(Darwin)
        XCTAssertEqual(s, "pi-ka-qiu")
        #else
        XCTAssertEqual(s, "figure")
        #endif
    }

    func testShortID() {
        var g = SeededGenerator(state: 42)
        let id = AssetNaming.shortID(using: &g)
        XCTAssertEqual(id.count, 6)
        XCTAssertTrue(id.allSatisfy { AssetNaming.shortIDAlphabet.contains($0) })
        XCTAssertNotEqual(AssetNaming.shortID(), AssetNaming.shortID(length: 12))
    }

    func testFolderNameAndDateInTimeZone() throws {
        // 2026-10-17T16:30:00Z is already 18 Oct in UTC+8 after 00:00? No: 16:30Z = 00:30+08:00 next day.
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-17T16:30:00Z"))
        let sh = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(AssetNaming.dateStamp(date, timeZone: sh), "20261018")
        XCTAssertEqual(AssetNaming.dateStamp(date, timeZone: utc), "20261017")
        XCTAssertEqual(AssetNaming.folderName(date: date, timeZone: sh, name: "Lego Bat", category: .brick, shortID: "abc234"),
                       "20261018_lego-bat_abc234")
        XCTAssertEqual(AssetNaming.iso8601(date, timeZone: sh), "2026-10-18T00:30:00+08:00")
    }

    func testFrameNaming() {
        XCTAssertEqual(AssetNaming.frameStem(1), "frame_00001")
        XCTAssertEqual(AssetLayout.relativeImagePath(index: 12, ext: "heic"), "raw/frame_00012.heic")
        let layout = AssetLayout(root: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(layout.transforms.path, "/tmp/x/transforms.json")
        XCTAssertEqual(layout.points.path, "/tmp/x/arkit/points3D.ply")
        XCTAssertEqual(AssetLayout.relativePointsPath, "arkit/points3D.ply")
        XCTAssertEqual(layout.confidenceURL(index: 3).lastPathComponent, "frame_00003_conf.png")
    }
}
