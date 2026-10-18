import RealityKit
import SwiftUI
import UIKit

/// Camera preview backed by RealityKit's `ARView`; we configure the session ourselves.
struct ARCaptureView: UIViewRepresentable {
    let host: any ARCaptureHost

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        host.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.host.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(host: host) }

    @MainActor
    final class Coordinator: NSObject {
        let host: any ARCaptureHost
        init(host: any ARCaptureHost) { self.host = host }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ARView else { return }
            host.handleTap(at: gesture.location(in: view), in: view)
        }
    }
}
