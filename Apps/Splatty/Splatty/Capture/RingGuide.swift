import RealityKit
import SplattyCore
import UIKit

/// A ring of segments drawn in AR around the object anchor, one segment per
/// azimuth bin of the active elevation ring. Grey = still needed,
/// green = covered, yellow = the next segment to walk to.
@MainActor
final class RingGuide {
    private let root: AnchorEntity
    private var segments: [ModelEntity] = []
    private var ring: ElevationRing?
    private var lastSignature: [Int] = []
    private let radius: Float

    private static let gray = UnlitMaterial(color: UIColor(white: 0.85, alpha: 1))
    private static let green = UnlitMaterial(color: .systemGreen)
    private static let yellow = UnlitMaterial(color: .systemYellow)

    init(anchor: Vec3, radius: Float, in view: ARView) {
        self.radius = radius
        root = AnchorEntity(world: anchor.simd)
        let dot = ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [UnlitMaterial(color: .systemYellow)])
        root.addChild(dot)
        view.scene.addAnchor(root)
    }

    func remove(from view: ARView) {
        view.scene.removeAnchor(root)
    }

    /// Rebuilds segments if the ring changed, then recolours.
    func update(coverage: CoverageMap, ring active: ElevationRing?, targetBin: Int?) {
        guard let active else {
            // Done: show every segment of the last ring green.
            for s in segments { s.model?.materials = [Self.green] }
            return
        }
        if active != ring { rebuild(ring: active, bins: coverage.bins(active)) }
        // 0 = gray, 1 = green, 2 = yellow
        let signature = (0..<segments.count).map { b in
            coverage.isCovered(active, bin: b) ? 1 : (b == targetBin ? 2 : 0)
        }
        guard signature != lastSignature else { return }
        for (b, state) in signature.enumerated() where lastSignature.count != signature.count || lastSignature[b] != state {
            let seg = segments[b]
            seg.model?.materials = [state == 1 ? Self.green : state == 2 ? Self.yellow : Self.gray]
            seg.scale = state == 2 ? SIMD3<Float>(1, 3, 1.4) : SIMD3<Float>(1, 1, 1)
        }
        lastSignature = signature
    }

    private func rebuild(ring: ElevationRing, bins: Int) {
        for s in segments { s.removeFromParent() }
        segments.removeAll()
        lastSignature = []
        self.ring = ring
        let arc = 2 * Float.pi * radius / Float(bins)
        let mesh = MeshResource.generateBox(width: arc * 0.72, height: 0.003, depth: 0.008, cornerRadius: 0.001)
        for b in 0..<bins {
            // Same azimuth convention as SplattyCore.Viewpoint: atan2(x, z).
            let theta = (Float(b) + 0.5) / Float(bins) * 2 * Float.pi
            let seg = ModelEntity(mesh: mesh, materials: [Self.gray])
            seg.position = SIMD3<Float>(radius * sin(theta), 0, radius * cos(theta))
            // Rotating local +X by theta about +Y gives the tangent (cos θ, 0, −sin θ).
            seg.orientation = simd_quatf(angle: theta, axis: SIMD3<Float>(0, 1, 0))
            root.addChild(seg)
            segments.append(seg)
        }
    }
}
