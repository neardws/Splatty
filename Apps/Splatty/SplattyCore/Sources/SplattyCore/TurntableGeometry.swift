import Foundation

/// A 2D vector / point in image pixel coordinates (x right, y down).
public struct Vec2: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
    public var length: Double { (x * x + y * y).squareRoot() }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
}

/// Axis-aligned rectangle in image pixels.
public struct PixelRect: Equatable, Sendable, Codable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
    public init(center c: Vec2, halfWidth hw: Double, halfHeight hh: Double) {
        self.init(minX: c.x - hw, minY: c.y - hh, maxX: c.x + hw, maxY: c.y + hh)
    }
    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    public func offset(by d: Vec2) -> PixelRect { PixelRect(minX: minX + d.x, minY: minY + d.y, maxX: maxX + d.x, maxY: maxY + d.y) }
    /// Scales about `origin`.
    public func scaled(_ s: Double, about o: Vec2) -> PixelRect {
        PixelRect(minX: o.x + (minX - o.x) * s, minY: o.y + (minY - o.y) * s,
                  maxX: o.x + (maxX - o.x) * s, maxY: o.y + (maxY - o.y) * s)
    }
    public func expanded(by f: Double) -> PixelRect { scaled(f, about: center) }
    public func clamped(width w: Double, height h: Double) -> PixelRect {
        PixelRect(minX: max(0, minX), minY: max(0, minY), maxX: min(w, maxX), maxY: min(h, maxY))
    }
    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
}

/// Image-space geometry for turntable capture. All image coordinates refer to the
/// stored sensor-native landscape image (ARKit `capturedImage`, x right, y down).
public enum TurntableGeometry {
    /// World up (+Y) expressed in the camera frame (ARKit/OpenGL camera axes:
    /// +X along the long edge towards the Home side, +Y up in landscape-right, +Z back).
    /// Valid in both capture modes: the phone's attitude w.r.t. gravity is always right.
    public static func gravityUpInCamera(_ c2w: Mat4) -> Vec3 {
        // u = R^T * (0,1,0) = second row of R.
        Vec3(c2w[1, 0], c2w[1, 1], c2w[1, 2]).normalized
    }

    /// Projects a world point into image pixels; nil if behind the camera.
    public static func project(_ p: Vec3, cameraToWorld c2w: Mat4, intrinsics k: Intrinsics) -> Vec2? {
        let d = p - c2w.translation
        // camera coords = R^T d
        let xc = c2w.axis(0).dot(d)
        let yc = c2w.axis(1).dot(d)
        let zc = c2w.axis(2).dot(d)
        guard zc < -1e-6 else { return nil }
        let x = k.fx * (xc / -zc) + k.cx
        let y = k.cy - k.fy * (yc / -zc)
        return Vec2(x, y)
    }

    /// Unit image direction of world "up" (nil when the camera looks almost straight up/down).
    public static func imageUp(_ c2w: Mat4, minTilt: Double = 0.3) -> Vec2? {
        let u = gravityUpInCamera(c2w)
        let v = Vec2(u.x, -u.y)
        let l = v.length
        guard l >= minTilt else { return nil }
        return v * (1 / l)
    }

    /// Unit image direction in which the visible surface of an object spinning about the
    /// vertical axis moves (perpendicular to image-up, pointing to image-"right").
    public static func horizontalAxis(_ c2w: Mat4, minTilt: Double = 0.3) -> Vec2? {
        guard let up = imageUp(c2w, minTilt: minTilt) else { return nil }
        return Vec2(-up.y, up.x)
    }

    /// Clockwise rotation (0/90/180/270) that makes the stored image upright.
    public static func uprightRotationCW(_ c2w: Mat4) -> Int {
        let u = gravityUpInCamera(c2w)
        // Angle of image-up measured clockwise from the image top (y-down coordinates).
        let phi = atan2(u.x, u.y) * 180 / .pi
        var r = Int((-phi / 90).rounded()) * 90
        r = ((r % 360) + 360) % 360
        return r
    }

    /// Elevation (degrees) of the camera above the object centre.
    public static func elevationDegrees(camera c2w: Mat4, objectCenter: Vec3) -> Double {
        Viewpoint.of(camera: c2w.translation, anchor: objectCenter).elevationDegrees
    }

    /// Half the object's apparent extent along `axis` (pixels), from its bounding box.
    public static func apparentRadius(box: PixelRect, axis: Vec2) -> Double {
        (abs(axis.x) * box.width + abs(axis.y) * box.height) / 2
    }

    /// Fallback apparent radius for an assumed object size when no subject mask exists.
    public static func assumedRadiusPixels(objectRadiusMeters: Double = 0.05, distance: Double, focal: Double) -> Double {
        objectRadiusMeters * focal / max(distance, 0.05)
    }
}
