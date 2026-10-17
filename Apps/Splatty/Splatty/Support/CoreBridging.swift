@preconcurrency import ARKit
import simd
import SplattyCore

extension Mat4 {
    /// From a column-major simd matrix (ARKit `camera.transform`, `worldTransform`).
    init(_ t: simd_float4x4) {
        let cols = [t.columns.0, t.columns.1, t.columns.2, t.columns.3]
        self.init(columns: cols.map { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] })
    }
}

extension Vec3 {
    init(_ v: SIMD3<Float>) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
    var simd: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

extension Intrinsics {
    /// ARKit intrinsics (column-major 3x3) for `camera.imageResolution`.
    init(_ camera: ARCamera) {
        let k = camera.intrinsics
        self.init(
            fx: Double(k.columns.0.x),
            fy: Double(k.columns.1.y),
            cx: Double(k.columns.2.x),
            cy: Double(k.columns.2.y),
            width: Int(camera.imageResolution.width.rounded()),
            height: Int(camera.imageResolution.height.rounded())
        )
    }
}

extension TrackingQuality {
    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            self = .normal
        case .notAvailable:
            self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .limited(reason: "initializing")
            case .excessiveMotion: self = .limited(reason: "excessive motion")
            case .insufficientFeatures: self = .limited(reason: "low texture")
            case .relocalizing: self = .limited(reason: "relocalizing")
            @unknown default: self = .limited(reason: "unknown")
            }
        }
    }
}

/// Wraps a non-Sendable value we hand across queues exactly once
/// (pixel buffers from ARKit are immutable after delivery).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
