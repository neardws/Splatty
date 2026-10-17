import Foundation

/// Minimal 3-vector used by the pure capture logic (no simd so it builds on Linux).
public struct Vec3: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }
}

/// Row-major 4x4 matrix. `m[r][c]`.
///
/// ARKit / simd matrices are column-major; convert with `Mat4(columns:)` or
/// the simd helpers in the app target.
public struct Mat4: Equatable, Sendable {
    public var m: [[Double]]

    public init(rows: [[Double]]) {
        precondition(rows.count == 4 && rows.allSatisfy { $0.count == 4 }, "Mat4 needs 4x4")
        m = rows
    }

    /// Build from four columns (simd / ARKit memory order).
    public init(columns c: [[Double]]) {
        precondition(c.count == 4 && c.allSatisfy { $0.count == 4 }, "Mat4 needs 4x4")
        m = (0..<4).map { r in (0..<4).map { col in c[col][r] } }
    }

    public static let identity = Mat4(rows: [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1],
    ])

    public subscript(r: Int, c: Int) -> Double {
        get { m[r][c] }
        set { m[r][c] = newValue }
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var out = [[Double]](repeating: [0, 0, 0, 0], count: 4)
        for r in 0..<4 {
            for c in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a.m[r][k] * b.m[k][c] }
                out[r][c] = s
            }
        }
        return Mat4(rows: out)
    }

    /// Translation column (camera centre for a camera-to-world matrix).
    public var translation: Vec3 { Vec3(m[0][3], m[1][3], m[2][3]) }

    /// Column `i` of the upper-left 3x3 (camera axis `i` in world space for c2w).
    public func axis(_ i: Int) -> Vec3 { Vec3(m[0][i], m[1][i], m[2][i]) }

    /// Upper-left 3x3 as rows.
    public var rotation: [[Double]] { (0..<3).map { r in Array(m[r][0..<3]) } }

    /// Translation from position + upper 3x3 rotation rows.
    public static func rigid(rotation r: [[Double]], translation t: Vec3) -> Mat4 {
        Mat4(rows: [
            [r[0][0], r[0][1], r[0][2], t.x],
            [r[1][0], r[1][1], r[1][2], t.y],
            [r[2][0], r[2][1], r[2][2], t.z],
            [0, 0, 0, 1],
        ])
    }

    /// Rotation about the world Y axis (radians), right-handed.
    public static func rotationY(_ a: Double) -> [[Double]] {
        [[cos(a), 0, sin(a)], [0, 1, 0], [-sin(a), 0, cos(a)]]
    }

    /// Rotation about the world X axis (radians), right-handed.
    public static func rotationX(_ a: Double) -> [[Double]] {
        [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]]
    }

    public static func matmul3(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0) { $0 + a[r][$1] * b[$1][c] } } }
    }
}

public enum PoseMath {
    /// Euclidean distance between two camera centres (metres).
    public static func translationDistance(_ a: Mat4, _ b: Mat4) -> Double {
        (a.translation - b.translation).length
    }

    /// Geodesic angle between the rotation parts of two poses, in degrees.
    /// angle = acos((trace(Ra^T Rb) - 1) / 2)
    public static func rotationAngleDegrees(_ a: Mat4, _ b: Mat4) -> Double {
        var trace = 0.0
        for i in 0..<3 {
            for k in 0..<3 { trace += a.m[k][i] * b.m[k][i] }
        }
        let c = max(-1.0, min(1.0, (trace - 1) / 2))
        return acos(c) * 180 / .pi
    }

    /// World-space viewing direction of a camera-to-world pose in ARKit/OpenGL
    /// convention (camera looks down its local -Z axis).
    public static func forward(_ c2w: Mat4) -> Vec3 { (-c2w.axis(2)).normalized }

    /// Point `distance` metres in front of the camera.
    public static func point(inFrontOf c2w: Mat4, distance: Double) -> Vec3 {
        c2w.translation + forward(c2w) * distance
    }

    /// Angle (degrees) between the camera's view direction and the direction to `target`.
    public static func offAxisAngleDegrees(_ c2w: Mat4, target: Vec3) -> Double {
        let toTarget = (target - c2w.translation).normalized
        let c = max(-1.0, min(1.0, forward(c2w).dot(toTarget)))
        return acos(c) * 180 / .pi
    }
}
