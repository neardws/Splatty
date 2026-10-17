import SplattyCore
import SwiftUI

struct CaptureView: View {
    @State var controller: CaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        ZStack {
            ARCaptureView(controller: controller)
                .ignoresSafeArea()

            if flash {
                Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            }

            VStack(spacing: 8) {
                topBar
                warningList
                Spacer()
                if !controller.anchorIsUserSet {
                    Text("Tap the object to set its center (yellow dot)")
                        .font(.footnote)
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
                coveragePanel
                controls
            }
            .padding()
        }
        .statusBarHidden()
        .onChange(of: controller.shutterFlash) {
            flash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                flash = false
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.stop()
                dismiss()
            } label: {
                Label("Done", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).font(.title)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(controller.shotCount) / \(controller.targetShots)")
                    .font(.title2.bold().monospacedDigit())
                Text("tracking: \(controller.trackingLabel)")
                    .font(.caption2)
                if controller.depthShotCount > 0 {
                    Text("depth: \(controller.depthShotCount)").font(.caption2)
                }
                if let d = controller.currentDistance {
                    Text(String(format: "dist %.0f cm", d * 100)).font(.caption2.monospacedDigit())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var warningList: some View {
        VStack(spacing: 4) {
            ForEach(controller.warnings, id: \.self) { w in
                Text(w.message)
                    .font(.footnote.bold())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(w == .notAimedAtObject ? Color.orange : Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            if let err = controller.lastError {
                Text(err)
                    .font(.caption)
                    .padding(6)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.yellow)
            }
        }
        .animation(.default, value: controller.warnings)
    }

    private var coveragePanel: some View {
        HStack(alignment: .center, spacing: 12) {
            CoverageRingsView(coverage: controller.coverage, current: controller.currentCell)
                .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 4) {
                CoverageLegend(coverage: controller.coverage)
                ProgressView(value: min(1, Double(controller.shotCount) / Double(max(controller.targetShots, 1))))
                    .tint(.green)
                Text(controller.videoFormatLabel).font(.caption2)
                if !controller.savedResolutionLabel.isEmpty {
                    Text("saved \(controller.savedResolutionLabel)").font(.caption2)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        HStack(alignment: .center) {
            VStack(spacing: 8) {
                Toggle("Auto", isOn: $controller.autoCapture)
                    .toggleStyle(.button)
                    .tint(.green)
                if controller.depthSupported {
                    Toggle("Depth", isOn: Binding(
                        get: { controller.depthEnabled },
                        set: { controller.setDepthEnabled($0) }
                    ))
                    .toggleStyle(.button)
                }
            }
            .frame(width: 90)

            Spacer()

            Button {
                controller.shutter()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 72, height: 72)
                    Circle().stroke(.black.opacity(0.3), lineWidth: 2).frame(width: 62, height: 62)
                    if controller.isSaving { ProgressView() }
                }
            }
            .disabled(controller.isSaving)
            .accessibilityLabel("Shutter")

            Spacer()

            VStack(spacing: 8) {
                if controller.exposureLockAvailable {
                    Toggle(isOn: Binding(
                        get: { controller.exposureLocked },
                        set: { controller.setExposureLocked($0) }
                    )) {
                        Label("AE/AF", systemImage: controller.exposureLocked ? "lock.fill" : "lock.open")
                    }
                    .toggleStyle(.button)
                }
            }
            .frame(width: 90)
        }
        .padding(.bottom, 8)
    }
}
