import Foundation

public enum DepthEncoding {
    /// Metres (Float32, ARKit `sceneDepth.depthMap`) → UInt16 millimetres for a
    /// 16-bit PNG. Invalid / non-positive values become 0 (Nerfstudio treats 0
    /// as "no depth"); values beyond 65.535 m clamp.
    /// Nerfstudio reads these with `depth_unit_scale_factor = 1e-3` (its default).
    public static func millimeters(fromMeters meters: [Float]) -> [UInt16] {
        meters.map { v in
            guard v.isFinite, v > 0 else { return 0 }
            let mm = (Double(v) * 1000).rounded()
            return mm >= 65535 ? UInt16.max : UInt16(mm)
        }
    }

    public static let unitScaleFactor = 0.001
}
