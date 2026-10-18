import Foundation

/// One captured view, serialised as a Nerfstudio `transforms.json` frame.
///
/// Standard Nerfstudio keys: `file_path`, `transform_matrix` (4x4 row-major,
/// camera-to-world, OpenGL convention), optional `depth_file_path`, and
/// per-frame intrinsics `fl_x fl_y cx cy w h` (Nerfstudio lets frames override
/// the top-level ones). Everything else is Splatty metadata that Nerfstudio
/// ignores.
public struct FrameRecord: Equatable, Sendable, Codable {
    public var index: Int
    /// Relative to the asset root (where transforms.json lives), e.g. `raw/frame_00001.jpg`.
    public var filePath: String
    public var depthFilePath: String?
    public var confidenceFilePath: String?
    /// Camera-to-world, Nerfstudio/OpenGL convention (== ARKit camera.transform).
    public var transform: Mat4
    public var intrinsics: Intrinsics
    /// ARFrame.timestamp (seconds since device boot).
    public var timestamp: Double
    /// Wall-clock time with timezone offset (ISO 8601).
    public var capturedAt: String
    public var exposureDuration: Double
    public var exposureOffset: Double
    public var ambientIntensity: Double?
    public var ambientColorTemperature: Double?
    public var tracking: String
    public var highResolution: Bool
    /// Timestamp of the frame the depth map came from (may differ for high-res stills).
    public var depthTimestamp: Double?
    /// Elevation ring / azimuth bin at capture time (nil if not aimed at anchor).
    public var ring: Int?
    public var azimuthBin: Int?
    /// False in turntable mode: `transform` is then the phone's ARKit pose, NOT the
    /// camera-to-object pose, and is written as `device_transform_matrix` instead of
    /// `transform_matrix` so nothing trains on it by accident.
    public var poseValid: Bool = true
    /// COLMAP-style mask (`masks/<image file name>.png`, white = object), also Nerfstudio `mask_path`.
    public var maskFilePath: String?
    /// Clockwise rotation (0/90/180/270) that makes the stored landscape image upright.
    public var uprightRotationCW: Int?
    /// How the phone was held (portrait / landscape_top_left / landscape_top_right / portrait_upside_down).
    public var deviceOrientation: String?
    /// World up in camera axes (OpenGL camera frame) — gravity is valid in every mode.
    public var gravityCamera: [Double]?
    /// Turntable: estimated object rotation (degrees, from image registration) at the shot.
    public var objectRotationDegrees: Double?
    /// Turntable: phone elevation above the object centre (degrees).
    public var elevationDegrees: Double?
    /// Turntable ring key: eye / high / top.
    public var turntableRing: String?

    public init(
        index: Int,
        filePath: String,
        depthFilePath: String? = nil,
        confidenceFilePath: String? = nil,
        transform: Mat4,
        intrinsics: Intrinsics,
        timestamp: Double,
        capturedAt: String,
        exposureDuration: Double,
        exposureOffset: Double,
        ambientIntensity: Double? = nil,
        ambientColorTemperature: Double? = nil,
        tracking: String,
        highResolution: Bool,
        depthTimestamp: Double? = nil,
        ring: Int? = nil,
        azimuthBin: Int? = nil
    ) {
        self.index = index
        self.filePath = filePath
        self.depthFilePath = depthFilePath
        self.confidenceFilePath = confidenceFilePath
        self.transform = transform
        self.intrinsics = intrinsics
        self.timestamp = timestamp
        self.capturedAt = capturedAt
        self.exposureDuration = exposureDuration
        self.exposureOffset = exposureOffset
        self.ambientIntensity = ambientIntensity
        self.ambientColorTemperature = ambientColorTemperature
        self.tracking = tracking
        self.highResolution = highResolution
        self.depthTimestamp = depthTimestamp
        self.ring = ring
        self.azimuthBin = azimuthBin
    }

    enum CodingKeys: String, CodingKey {
        case index = "splatty_index"
        case filePath = "file_path"
        case depthFilePath = "depth_file_path"
        case confidenceFilePath = "confidence_file_path"
        case transformMatrix = "transform_matrix"
        case flX = "fl_x", flY = "fl_y", cx, cy, w, h
        case timestamp
        case capturedAt = "captured_at"
        case exposureDuration = "exposure_duration"
        case exposureOffset = "exposure_offset"
        case ambientIntensity = "ambient_intensity"
        case ambientColorTemperature = "ambient_color_temperature"
        case tracking
        case highResolution = "high_resolution"
        case depthTimestamp = "depth_timestamp"
        case ring
        case azimuthBin = "azimuth_bin"
        case poseValid = "pose_valid"
        case deviceTransformMatrix = "device_transform_matrix"
        case maskFilePath = "mask_path"
        case uprightRotationCW = "upright_rotation_cw"
        case deviceOrientation = "device_orientation"
        case gravityCamera = "gravity_camera"
        case objectRotationDegrees = "object_rotation_deg"
        case elevationDegrees = "elevation_deg"
        case turntableRing = "turntable_ring"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        filePath = try c.decode(String.self, forKey: .filePath)
        depthFilePath = try c.decodeIfPresent(String.self, forKey: .depthFilePath)
        confidenceFilePath = try c.decodeIfPresent(String.self, forKey: .confidenceFilePath)
        poseValid = try c.decodeIfPresent(Bool.self, forKey: .poseValid) ?? true
        let rows = try c.decodeIfPresent([[Double]].self, forKey: .transformMatrix)
            ?? c.decode([[Double]].self, forKey: .deviceTransformMatrix)
        guard rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else {
            throw DecodingError.dataCorruptedError(forKey: .transformMatrix, in: c, debugDescription: "expected 4x4")
        }
        transform = Mat4(rows: rows)
        intrinsics = Intrinsics(
            fx: try c.decode(Double.self, forKey: .flX),
            fy: try c.decode(Double.self, forKey: .flY),
            cx: try c.decode(Double.self, forKey: .cx),
            cy: try c.decode(Double.self, forKey: .cy),
            width: try c.decode(Int.self, forKey: .w),
            height: try c.decode(Int.self, forKey: .h)
        )
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        capturedAt = try c.decode(String.self, forKey: .capturedAt)
        exposureDuration = try c.decode(Double.self, forKey: .exposureDuration)
        exposureOffset = try c.decode(Double.self, forKey: .exposureOffset)
        ambientIntensity = try c.decodeIfPresent(Double.self, forKey: .ambientIntensity)
        ambientColorTemperature = try c.decodeIfPresent(Double.self, forKey: .ambientColorTemperature)
        tracking = try c.decode(String.self, forKey: .tracking)
        highResolution = try c.decode(Bool.self, forKey: .highResolution)
        depthTimestamp = try c.decodeIfPresent(Double.self, forKey: .depthTimestamp)
        ring = try c.decodeIfPresent(Int.self, forKey: .ring)
        azimuthBin = try c.decodeIfPresent(Int.self, forKey: .azimuthBin)
        maskFilePath = try c.decodeIfPresent(String.self, forKey: .maskFilePath)
        uprightRotationCW = try c.decodeIfPresent(Int.self, forKey: .uprightRotationCW)
        deviceOrientation = try c.decodeIfPresent(String.self, forKey: .deviceOrientation)
        gravityCamera = try c.decodeIfPresent([Double].self, forKey: .gravityCamera)
        objectRotationDegrees = try c.decodeIfPresent(Double.self, forKey: .objectRotationDegrees)
        elevationDegrees = try c.decodeIfPresent(Double.self, forKey: .elevationDegrees)
        turntableRing = try c.decodeIfPresent(String.self, forKey: .turntableRing)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(filePath, forKey: .filePath)
        try c.encodeIfPresent(depthFilePath, forKey: .depthFilePath)
        try c.encodeIfPresent(confidenceFilePath, forKey: .confidenceFilePath)
        if poseValid {
            try c.encode(transform.m, forKey: .transformMatrix)
        } else {
            try c.encode(false, forKey: .poseValid)
            try c.encode(transform.m, forKey: .deviceTransformMatrix)
        }
        try c.encode(intrinsics.fx, forKey: .flX)
        try c.encode(intrinsics.fy, forKey: .flY)
        try c.encode(intrinsics.cx, forKey: .cx)
        try c.encode(intrinsics.cy, forKey: .cy)
        try c.encode(intrinsics.width, forKey: .w)
        try c.encode(intrinsics.height, forKey: .h)
        // JSONEncoder throws on NaN/inf (ARKit hi-res frames can report NaN light
        // estimates / exposure offsets), which once silently killed transforms.json and
        // meta.json for a whole capture. Required numbers fall back to 0, optionals are dropped.
        try c.encode(Finite.or0(timestamp), forKey: .timestamp)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(Finite.or0(exposureDuration), forKey: .exposureDuration)
        try c.encode(Finite.or0(exposureOffset), forKey: .exposureOffset)
        try c.encodeIfPresent(Finite.orNil(ambientIntensity), forKey: .ambientIntensity)
        try c.encodeIfPresent(Finite.orNil(ambientColorTemperature), forKey: .ambientColorTemperature)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(highResolution, forKey: .highResolution)
        try c.encodeIfPresent(Finite.orNil(depthTimestamp), forKey: .depthTimestamp)
        try c.encodeIfPresent(ring, forKey: .ring)
        try c.encodeIfPresent(azimuthBin, forKey: .azimuthBin)
        try c.encodeIfPresent(maskFilePath, forKey: .maskFilePath)
        try c.encodeIfPresent(uprightRotationCW, forKey: .uprightRotationCW)
        try c.encodeIfPresent(deviceOrientation, forKey: .deviceOrientation)
        try c.encodeIfPresent(gravityCamera.flatMap { $0.allSatisfy(\.isFinite) ? $0 : nil }, forKey: .gravityCamera)
        try c.encodeIfPresent(Finite.orNil(objectRotationDegrees), forKey: .objectRotationDegrees)
        try c.encodeIfPresent(Finite.orNil(elevationDegrees), forKey: .elevationDegrees)
        try c.encodeIfPresent(turntableRing, forKey: .turntableRing)
    }
}

public extension FrameRecord {
    /// Pose and intrinsics are all finite and usable (frames failing this are left out of transforms.json).
    var hasFiniteGeometry: Bool {
        transform.m.allSatisfy { $0.allSatisfy(\.isFinite) }
            && [intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy].allSatisfy(\.isFinite)
            && intrinsics.fx > 0 && intrinsics.fy > 0 && intrinsics.width > 0 && intrinsics.height > 0
    }
}

/// NaN/inf guards for JSON encoding.
public enum Finite {
    public static func or0(_ v: Double) -> Double { v.isFinite ? v : 0 }
    public static func orNil(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
}

/// Nerfstudio-compatible `transforms.json` written to the asset root.
public struct TransformsDocument: Equatable, Sendable, Codable {
    public static let currentSplattyFormat = 2

    public var cameraModel: String = "OPENCV"
    public var intrinsics: Intrinsics
    public var k1 = 0.0, k2 = 0.0, p1 = 0.0, p2 = 0.0
    public var frames: [FrameRecord]
    /// Splatty extras (ignored by Nerfstudio).
    public var splattyFormat: Int = TransformsDocument.currentSplattyFormat
    public var poseSource = "arkit"
    public var cameraConvention = "opengl_c2w (ARKit camera.transform, image in sensor-native landscape orientation)"
    public var worldConvention = "arkit_world_y_up_meters"
    public var depthUnitScaleFactor: Double? = nil
    public var objectAnchor: [Double]? = nil
    /// Seed point cloud (Nerfstudio/msplat `ply_file_path`), relative to the asset root.
    public var plyFilePath: String? = nil
    /// `orbit` (ARKit poses valid) or `turntable` (poses must come from SfM on the Mac).
    public var captureMode: CaptureMode = .orbit
    /// False when frames carry no usable `transform_matrix` (turntable): run COLMAP first.
    public var posesValid = true
    /// Where `mask_path` masks came from, e.g. `vision_preliminary`.
    public var maskSource: String? = nil

    public init(intrinsics: Intrinsics, frames: [FrameRecord]) {
        self.intrinsics = intrinsics
        self.frames = frames
    }

    /// Builds a document whose top-level intrinsics come from the first frame.
    public static func make(frames: [FrameRecord], objectAnchor: Vec3? = nil, plyFilePath: String? = nil,
                            captureMode: CaptureMode = .orbit, maskSource: String? = nil) -> TransformsDocument? {
        let frames = frames.filter(\.hasFiniteGeometry)
        guard let first = frames.first else { return nil }
        var doc = TransformsDocument(intrinsics: first.intrinsics, frames: frames)
        doc.captureMode = captureMode
        if !captureMode.arkitPosesAreObjectPoses || frames.contains(where: { !$0.poseValid }) {
            doc.posesValid = false
            doc.poseSource = "none_needs_sfm"
            doc.cameraConvention = "no object poses: frames carry device_transform_matrix (ARKit phone pose, world-static scene, NOT camera-to-object); images in sensor-native landscape orientation"
        }
        if frames.contains(where: { $0.maskFilePath != nil }) { doc.maskSource = maskSource }
        if frames.contains(where: { $0.depthFilePath != nil }) {
            doc.depthUnitScaleFactor = DepthEncoding.unitScaleFactor
        }
        doc.objectAnchor = objectAnchor.flatMap { a in
            [a.x, a.y, a.z].allSatisfy(\.isFinite) ? [a.x, a.y, a.z] : nil
        }
        doc.plyFilePath = plyFilePath
        return doc
    }

    enum CodingKeys: String, CodingKey {
        case cameraModel = "camera_model"
        case flX = "fl_x", flY = "fl_y", cx, cy, w, h
        case k1, k2, p1, p2
        case frames
        case splattyFormat = "splatty_format"
        case poseSource = "splatty_pose_source"
        case cameraConvention = "splatty_camera_convention"
        case worldConvention = "splatty_world_convention"
        case depthUnitScaleFactor = "depth_unit_scale_factor"
        case objectAnchor = "splatty_object_anchor"
        case plyFilePath = "ply_file_path"
        case captureMode = "splatty_capture_mode"
        case posesValid = "splatty_poses_valid"
        case maskSource = "splatty_mask_source"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraModel = try c.decodeIfPresent(String.self, forKey: .cameraModel) ?? "OPENCV"
        intrinsics = Intrinsics(
            fx: try c.decode(Double.self, forKey: .flX),
            fy: try c.decode(Double.self, forKey: .flY),
            cx: try c.decode(Double.self, forKey: .cx),
            cy: try c.decode(Double.self, forKey: .cy),
            width: try c.decode(Int.self, forKey: .w),
            height: try c.decode(Int.self, forKey: .h)
        )
        k1 = try c.decodeIfPresent(Double.self, forKey: .k1) ?? 0
        k2 = try c.decodeIfPresent(Double.self, forKey: .k2) ?? 0
        p1 = try c.decodeIfPresent(Double.self, forKey: .p1) ?? 0
        p2 = try c.decodeIfPresent(Double.self, forKey: .p2) ?? 0
        frames = try c.decode([FrameRecord].self, forKey: .frames)
        splattyFormat = try c.decodeIfPresent(Int.self, forKey: .splattyFormat) ?? 1
        poseSource = try c.decodeIfPresent(String.self, forKey: .poseSource) ?? "arkit"
        cameraConvention = try c.decodeIfPresent(String.self, forKey: .cameraConvention) ?? ""
        worldConvention = try c.decodeIfPresent(String.self, forKey: .worldConvention) ?? ""
        depthUnitScaleFactor = try c.decodeIfPresent(Double.self, forKey: .depthUnitScaleFactor)
        objectAnchor = try c.decodeIfPresent([Double].self, forKey: .objectAnchor)
        plyFilePath = try c.decodeIfPresent(String.self, forKey: .plyFilePath)
        captureMode = try c.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .orbit
        posesValid = try c.decodeIfPresent(Bool.self, forKey: .posesValid) ?? true
        maskSource = try c.decodeIfPresent(String.self, forKey: .maskSource)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cameraModel, forKey: .cameraModel)
        try c.encode(intrinsics.fx, forKey: .flX)
        try c.encode(intrinsics.fy, forKey: .flY)
        try c.encode(intrinsics.cx, forKey: .cx)
        try c.encode(intrinsics.cy, forKey: .cy)
        try c.encode(intrinsics.width, forKey: .w)
        try c.encode(intrinsics.height, forKey: .h)
        try c.encode(k1, forKey: .k1)
        try c.encode(k2, forKey: .k2)
        try c.encode(p1, forKey: .p1)
        try c.encode(p2, forKey: .p2)
        try c.encode(frames, forKey: .frames)
        try c.encode(splattyFormat, forKey: .splattyFormat)
        try c.encode(poseSource, forKey: .poseSource)
        try c.encode(cameraConvention, forKey: .cameraConvention)
        try c.encode(worldConvention, forKey: .worldConvention)
        try c.encodeIfPresent(depthUnitScaleFactor, forKey: .depthUnitScaleFactor)
        try c.encodeIfPresent(objectAnchor, forKey: .objectAnchor)
        try c.encodeIfPresent(plyFilePath, forKey: .plyFilePath)
        try c.encode(captureMode, forKey: .captureMode)
        try c.encode(posesValid, forKey: .posesValid)
        try c.encodeIfPresent(maskSource, forKey: .maskSource)
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> TransformsDocument {
        try JSONDecoder().decode(TransformsDocument.self, from: data)
    }
}
