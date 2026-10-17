import Foundation

/// Camera coordinate conventions.
///
/// ARKit `ARCamera.transform` is camera-to-world. Its camera frame is defined
/// relative to the sensor's native (landscape-right) orientation:
///   +X right (along the long edge), +Y up, +Z towards the viewer;
///   the camera looks down -Z.
/// World frame: Y up (gravity), right-handed, metres.
///
/// That is exactly the OpenGL / Blender / Nerfstudio `transforms.json`
/// convention, and Splatty saves `ARFrame.capturedImage` in the same native
/// orientation (no rotation), so `transform_matrix` = `ARCamera.transform`
/// as-is (re-ordered to row-major).
///
/// OpenCV / COLMAP use +X right, +Y down, +Z forward. To get an OpenCV c2w,
/// right-multiply by diag(1, -1, -1, 1) (flip camera Y and Z axes).
public enum CameraConvention {
    public static let flipYZ = Mat4(rows: [
        [1, 0, 0, 0],
        [0, -1, 0, 0],
        [0, 0, -1, 0],
        [0, 0, 0, 1],
    ])

    /// ARKit camera-to-world → Nerfstudio / OpenGL camera-to-world (identity).
    public static func arkitToNerfstudio(_ c2w: Mat4) -> Mat4 { c2w }

    /// ARKit camera-to-world → OpenCV / COLMAP camera-to-world.
    public static func arkitToOpenCV(_ c2w: Mat4) -> Mat4 { c2w * flipYZ }
}

/// Pinhole intrinsics in pixels for an image of size `width` x `height`.
public struct Intrinsics: Equatable, Sendable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Rescale to a different image size of the same sensor crop
    /// (e.g. ARKit reports intrinsics for `imageResolution` but the buffer differs).
    public func scaled(toWidth w: Int, height h: Int) -> Intrinsics {
        guard width > 0, height > 0, w != width || h != height else { return self }
        let sx = Double(w) / Double(width)
        let sy = Double(h) / Double(height)
        return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }

    /// Horizontal field of view in degrees.
    public var horizontalFOVDegrees: Double { 2 * atan(Double(width) / (2 * fx)) * 180 / .pi }
}
