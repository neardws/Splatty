import Foundation

public enum AssetCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case figure, badge, brick, toy, other
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .figure: "Figure 手办"
        case .badge: "Badge 吧唧"
        case .brick: "Brick 积木"
        case .toy: "Toy 玩具"
        case .other: "Other 其他"
        }
    }
}

public enum AssetStatus: String, Codable, Sendable {
    /// Created, no shots yet (Splatty addition to the architecture doc's states).
    case draft
    case captured
    case processing
    case ready
    case failed
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    /// Marketing-ish model name, e.g. "iPhone".
    public var model: String
    /// Hardware identifier, e.g. "iPhone17,1".
    public var identifier: String
    public var systemVersion: String
    public var hasLiDAR: Bool

    public init(model: String, identifier: String, systemVersion: String, hasLiDAR: Bool) {
        self.model = model
        self.identifier = identifier
        self.systemVersion = systemVersion
        self.hasLiDAR = hasLiDAR
    }
}

public struct AssetCounts: Codable, Sendable, Equatable {
    public var images: Int
    public var depth: Int
    public init(images: Int = 0, depth: Int = 0) {
        self.images = images
        self.depth = depth
    }
}

public struct CaptureSettingsRecord: Codable, Sendable, Equatable {
    public var targetShots: Int
    public var imageFormat: String
    public var highResolutionFrames: Bool
    public var depthEnabled: Bool
    public var videoFormat: String?
    public var exposureLocked: Bool
    /// v2 (optional so v1 files still decode).
    public var whiteBalanceLocked: Bool?
    public var focusLocked: Bool?
    public var captureMode: CaptureMode?
    /// Plan preset key (quick / standard / detailed).
    public var preset: String?
    public var voicePrompts: Bool?

    public init(targetShots: Int, imageFormat: String, highResolutionFrames: Bool, depthEnabled: Bool, videoFormat: String?, exposureLocked: Bool) {
        self.targetShots = targetShots
        self.imageFormat = imageFormat
        self.highResolutionFrames = highResolutionFrames
        self.depthEnabled = depthEnabled
        self.videoFormat = videoFormat
        self.exposureLocked = exposureLocked
    }
}

/// Foreground masks saved next to the images.
public struct MaskInfo: Codable, Sendable, Equatable {
    /// `vision_preliminary`: Apple Vision subject lifting on device; the Mac may redo
    /// them (BiRefNet / SAM 2) before COLMAP.
    public var source: String
    public var folder: String
    /// `colmap`: masks/<image file name>.png, 8-bit, 255 = keep (object), 0 = ignore.
    public var convention: String
    public var count: Int

    public static let visionPreliminary = "vision_preliminary"

    public init(source: String = MaskInfo.visionPreliminary, folder: String = AssetLayout.masksFolder,
                convention: String = "colmap: masks/<image file name>.png, 255 = object (keep), 0 = ignore",
                count: Int) {
        self.source = source
        self.folder = folder
        self.convention = convention
        self.count = count
    }
}

/// `meta.json` at the root of each asset folder.
public struct AssetMeta: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int = AssetMeta.currentSchemaVersion
    public var id: String
    /// Folder name `YYYYMMDD_<slug>_<shortid>`.
    public var folder: String
    public var name: String
    public var category: AssetCategory
    /// ISO 8601 with offset, e.g. 2026-10-17T16:00:00+08:00.
    public var createdAt: String
    /// Time of the last shot, ISO 8601 with offset. nil while draft.
    public var capturedAt: String?
    public var timeZone: String
    public var status: AssetStatus
    public var device: DeviceInfo?
    public var counts: AssetCounts
    public var capture: CaptureSettingsRecord?
    public var splatVersion: String?
    public var notes: String
    public var appVersion: String?
    /// v2: `turntable` or `orbit` (nil in v1 files = orbit).
    public var captureMode: CaptureMode?
    /// v2: false for turntable captures — transforms.json has no object poses; run SfM.
    public var posesValid: Bool?
    /// v2: foreground masks saved with the shots, if any.
    public var masks: MaskInfo?

    public init(
        id: String,
        folder: String,
        name: String,
        category: AssetCategory,
        createdAt: String,
        timeZone: String,
        status: AssetStatus = .draft,
        notes: String = ""
    ) {
        self.id = id
        self.folder = folder
        self.name = name
        self.category = category
        self.createdAt = createdAt
        self.timeZone = timeZone
        self.status = status
        self.counts = AssetCounts()
        self.notes = notes
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> AssetMeta {
        try JSONDecoder().decode(AssetMeta.self, from: data)
    }
}
