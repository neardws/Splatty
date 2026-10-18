import Foundation

/// On-disk layout of one asset (see docs/architecture.md):
///
///     Documents/Splatty/<YYYYMMDD>_<slug>_<shortid>/
///       meta.json
///       cover.jpg
///       raw/frame_00001.jpg            RGB, sensor-native landscape orientation
///       depth/frame_00001.png          16-bit PNG, millimetres (LiDAR only)
///       depth/frame_00001_conf.png     8-bit PNG, ARConfidenceLevel 0/1/2
///       transforms.json                Nerfstudio-format poses/intrinsics (msplat reads this)
///       arkit/points3D.ply             seed points (orbit mode only)
///       masks/frame_00001.jpg.png      foreground mask, COLMAP naming (turntable mode)
///       splat/v001/                    (later, from the Mac mini)
///
/// All paths inside transforms.json are relative to the asset root and never
/// start with "./" (msplat resolves leading-"." paths against the CWD).
public struct AssetLayout: Sendable, Equatable {
    public static let libraryFolder = "Splatty"
    public static let rawFolder = "raw"
    public static let depthFolder = "depth"
    public static let arkitFolder = "arkit"
    public static let masksFolder = "masks"
    public static let splatFolder = "splat"
    public static let metaFile = "meta.json"
    public static let transformsFile = "transforms.json"
    public static let pointsFile = "points3D.ply"
    public static let coverFile = "cover.jpg"
    public static let logFile = "capture_log.json"

    public let root: URL

    public init(root: URL) { self.root = root }

    public var meta: URL { root.appendingPathComponent(Self.metaFile) }
    public var cover: URL { root.appendingPathComponent(Self.coverFile) }
    public var raw: URL { root.appendingPathComponent(Self.rawFolder, isDirectory: true) }
    public var depth: URL { root.appendingPathComponent(Self.depthFolder, isDirectory: true) }
    public var arkit: URL { root.appendingPathComponent(Self.arkitFolder, isDirectory: true) }
    public var masks: URL { root.appendingPathComponent(Self.masksFolder, isDirectory: true) }

    /// COLMAP mask naming: `masks/<image file name>.png`.
    public func maskURL(index: Int, imageExt: String) -> URL {
        masks.appendingPathComponent("\(AssetNaming.frameStem(index)).\(imageExt).png")
    }

    public static func relativeMaskPath(index: Int, imageExt: String) -> String {
        "\(masksFolder)/\(AssetNaming.frameStem(index)).\(imageExt).png"
    }
    public var transforms: URL { root.appendingPathComponent(Self.transformsFile) }
    public var log: URL { root.appendingPathComponent(Self.logFile) }
    public var points: URL { arkit.appendingPathComponent(Self.pointsFile) }

    public func imageURL(index: Int, ext: String) -> URL {
        raw.appendingPathComponent("\(AssetNaming.frameStem(index)).\(ext)")
    }

    public func depthURL(index: Int) -> URL {
        depth.appendingPathComponent("\(AssetNaming.frameStem(index)).png")
    }

    public func confidenceURL(index: Int) -> URL {
        depth.appendingPathComponent("\(AssetNaming.frameStem(index))_conf.png")
    }

    /// Paths as written into transforms.json (relative to the asset root).
    public static func relativeImagePath(index: Int, ext: String) -> String {
        "\(rawFolder)/\(AssetNaming.frameStem(index)).\(ext)"
    }

    public static func relativeDepthPath(index: Int) -> String {
        "\(depthFolder)/\(AssetNaming.frameStem(index)).png"
    }

    public static func relativeConfidencePath(index: Int) -> String {
        "\(depthFolder)/\(AssetNaming.frameStem(index))_conf.png"
    }
}

extension AssetLayout {
    /// `ply_file_path` value in transforms.json.
    public static var relativePointsPath: String { "\(arkitFolder)/\(pointsFile)" }
}
