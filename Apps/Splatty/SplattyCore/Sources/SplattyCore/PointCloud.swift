import Foundation

public struct ColoredPoint: Equatable, Sendable {
    public var position: Vec3
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ position: Vec3, r: UInt8 = 128, g: UInt8 = 128, b: UInt8 = 128) {
        self.position = position
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Voxel-deduplicated seed point cloud (ARKit feature points + LiDAR samples).
/// msplat initialises Gaussians from these points; without a PLY it has nothing to train.
public struct PointCloudAccumulator: Sendable {
    public let voxelSize: Double
    public let maxPoints: Int
    public private(set) var points: [ColoredPoint] = []
    private var occupied: Set<VoxelKey> = []

    struct VoxelKey: Hashable, Sendable {
        let x: Int32, y: Int32, z: Int32
    }

    public init(voxelSize: Double = 0.004, maxPoints: Int = 300_000) {
        self.voxelSize = voxelSize
        self.maxPoints = maxPoints
    }

    /// Adds a point unless its voxel is already occupied. Returns true if added.
    @discardableResult
    public mutating func add(_ p: ColoredPoint) -> Bool {
        guard points.count < maxPoints,
              p.position.x.isFinite, p.position.y.isFinite, p.position.z.isFinite else { return false }
        let key = VoxelKey(
            x: Int32(clamping: Int((p.position.x / voxelSize).rounded(.down))),
            y: Int32(clamping: Int((p.position.y / voxelSize).rounded(.down))),
            z: Int32(clamping: Int((p.position.z / voxelSize).rounded(.down)))
        )
        guard occupied.insert(key).inserted else { return false }
        points.append(p)
        return true
    }

    public mutating func add(contentsOf ps: [ColoredPoint]) {
        for p in ps { add(p) }
    }

    public var count: Int { points.count }
}

public enum PLYWriter {
    /// binary_little_endian PLY with float x,y,z + uchar red,green,blue
    /// (the layout msplat / Nerfstudio / COLMAP-exported PLYs use).
    public static func binary(_ points: [ColoredPoint]) -> Data {
        var data = Data()
        let header = """
        ply
        format binary_little_endian 1.0
        comment Splatty ARKit seed points (ARKit world frame, metres)
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        data.append(header.data(using: .ascii)!)
        data.reserveCapacity(data.count + points.count * 15)
        for p in points {
            for v in [Float(p.position.x), Float(p.position.y), Float(p.position.z)] {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: [p.r, p.g, p.b])
        }
        return data
    }
}

public enum DepthUnprojection {
    /// World point for depth pixel (u, v) (integer pixel indices of a depth map
    /// whose intrinsics are `k`) at metric depth `d`, for an ARKit camera-to-world pose.
    /// Pixel centres are at +0.5. Image rows go down, so camera-space y is negated.
    public static func worldPoint(u: Int, v: Int, depth d: Double, intrinsics k: Intrinsics, cameraToWorld c2w: Mat4) -> Vec3 {
        let xc = (Double(u) + 0.5 - k.cx) / k.fx * d
        let yc = (Double(v) + 0.5 - k.cy) / k.fy * d
        // OpenCV camera (x right, y down, z fwd) → ARKit camera (x right, y up, -z fwd).
        let p = Vec3(xc, -yc, -d)
        let m = c2w.m
        return Vec3(
            m[0][0] * p.x + m[0][1] * p.y + m[0][2] * p.z + m[0][3],
            m[1][0] * p.x + m[1][1] * p.y + m[1][2] * p.z + m[1][3],
            m[2][0] * p.x + m[2][1] * p.y + m[2][2] * p.z + m[2][3]
        )
    }
}

public enum ColorConversion {
    /// Full-range BT.601 YCbCr → RGB (ARKit `capturedImage` is 420f).
    public static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let yy = Double(y), u = Double(cb) - 128, v = Double(cr) - 128
        func clamp(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x.rounded()))) }
        return (clamp(yy + 1.402 * v), clamp(yy - 0.344136 * u - 0.714136 * v), clamp(yy + 1.772 * u))
    }
}

public enum DepthSampler {
    public struct Sample: Equatable, Sendable {
        public var u: Int
        public var v: Int
        public var world: Vec3
    }

    /// Back-projects every `stride`-th depth pixel to world space.
    /// - Parameters:
    ///   - depth: row-major metres, `width * height`.
    ///   - confidence: optional row-major ARConfidenceLevel values (0/1/2).
    ///   - intrinsics: intrinsics already scaled to the depth map size.
    public static func samples(
        depth: [Float], confidence: [UInt8]?, width: Int, height: Int,
        stride: Int = 8, minConfidence: UInt8 = 2,
        minDepth: Double = 0.1, maxDepth: Double = 1.5,
        intrinsics: Intrinsics, cameraToWorld: Mat4
    ) -> [Sample] {
        guard width > 0, height > 0, depth.count >= width * height, stride > 0 else { return [] }
        var out: [Sample] = []
        var v = stride / 2
        while v < height {
            var u = stride / 2
            while u < width {
                let i = v * width + u
                let d = Double(depth[i])
                let confOK = confidence.map { $0.count > i && $0[i] >= minConfidence } ?? true
                if d.isFinite, d >= minDepth, d <= maxDepth, confOK {
                    out.append(Sample(u: u, v: v, world: DepthUnprojection.worldPoint(
                        u: u, v: v, depth: d, intrinsics: intrinsics, cameraToWorld: cameraToWorld)))
                }
                u += stride
            }
            v += stride
        }
        return out
    }
}
