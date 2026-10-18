import SplattyCore
import SwiftUI

struct CaptureView: View {
    @State var controller: CaptureController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding.v1.done") private var onboardingDone = false
    @State private var flash = false

    var body: some View {
        ZStack {
            ARCaptureView(host: controller)
                .ignoresSafeArea()

            if flash {
                Color.white.opacity(0.3).ignoresSafeArea().allowsHitTesting(false)
            }

            switch controller.phase {
            case .placing: placingOverlay
            case .capturing, .done: capturingOverlay
            }

            if controller.phase == .done, !controller.keepGoing {
                DoneCard(shots: controller.shotCount,
                         onFinish: close,
                         onContinue: { controller.continueShooting() })
                    .transition(.scale.combined(with: .opacity))
            }

            if !onboardingDone {
                Color.black.opacity(0.35).ignoresSafeArea()
                OnboardingView { withAnimation { onboardingDone = true } }
            }
        }
        .animation(.spring(duration: 0.35), value: controller.phase)
        .animation(.spring(duration: 0.35), value: controller.completedRing)
        .statusBarHidden()
        .onChange(of: controller.shutterFlash) {
            flash = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                flash = false
            }
        }
    }

    private func close() {
        controller.stop()
        dismiss()
    }

    // MARK: - Placing

    private var placingOverlay: some View {
        VStack {
            HStack {
                closeButton
                Spacer()
                helpButton
            }
            Spacer()
            ZStack {
                Circle().stroke(.white, lineWidth: 2).frame(width: 70, height: 70)
                Circle().fill(.yellow).frame(width: 8, height: 8)
            }
            .allowsHitTesting(false)
            Spacer()
            VStack(spacing: 10) {
                Text("第一步：对准物体，轻点它的中心")
                    .font(.headline)
                Text("让物体在画面中间，距离 20–40 厘米")
                    .font(.subheadline)
                if !controller.trackingText.isEmpty {
                    Text(controller.trackingText).font(.footnote).foregroundStyle(.yellow)
                }
                if let err = controller.lastError {
                    Text(err).font(.footnote).foregroundStyle(.yellow)
                }
                Button("就是中间这个") { controller.setAnchorAtCenter() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!controller.trackingIsNormal)
            }
            .foregroundStyle(.white)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding()
    }

    // MARK: - Capturing

    private var capturingOverlay: some View {
        VStack(spacing: 10) {
            topBar
            GuidancePill(hint: controller.hint, keepGoing: controller.keepGoing)
            if let w = controller.rejection {
                Text(CaptureStrings.warning(w))
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .transition(.opacity)
            } else if !controller.trackingText.isEmpty {
                Text(controller.trackingText)
                    .font(.subheadline.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
            if let r = controller.completedRing, let next = controller.activeRing {
                RingDoneCard(done: r, next: next, onSkip: { controller.skipActiveRing() },
                             onDismiss: { controller.dismissRingCard() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            bottomPanel
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: controller.rejection)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            closeButton
            Spacer()
            VStack(spacing: 2) {
                if let r = controller.activeRing,
                   let i = controller.plan.order.firstIndex(of: r) {
                    Text("第 \(i + 1)/\(controller.plan.order.count) 圈 · \(CaptureStrings.ringName(r))")
                        .font(.headline)
                    Text(CaptureStrings.ringHowTo(r)).font(.caption)
                } else {
                    Text("全部完成").font(.headline)
                }
                Text("已拍 \(controller.shotCount) 张 · 目标 \(controller.targetShots)")
                    .font(.caption.monospacedDigit())
            }
            Spacer()
            moreMenu
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var bottomPanel: some View {
        HStack(alignment: .bottom, spacing: 12) {
            CoverageRingsView(coverage: controller.coverage,
                              current: controller.hint?.currentCell,
                              activeRing: controller.activeRing,
                              targetBin: controller.hint?.targetBin,
                              skipped: controller.skippedRings)
                .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                RingProgressList(progress: controller.ringProgress, active: controller.activeRing)
                if let d = controller.currentDistance {
                    Text(String(format: "距离 %.0f 厘米", d * 100)).font(.caption2.monospacedDigit())
                }
            }
            Spacer(minLength: 0)
            Button {
                controller.shutter()
            } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.9)).frame(width: 52, height: 52)
                    if controller.isSaving { ProgressView() } else {
                        Image(systemName: "camera.fill").foregroundStyle(.black)
                    }
                }
            }
            .disabled(controller.isSaving)
            .accessibilityLabel("手动补拍")
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white, .black.opacity(0.4))
        }
        .accessibilityLabel("关闭")
    }

    private var helpButton: some View {
        Button { onboardingDone = false } label: {
            Image(systemName: "questionmark.circle.fill").font(.title).foregroundStyle(.white, .black.opacity(0.4))
        }
        .accessibilityLabel("使用说明")
    }

    private var moreMenu: some View {
        Menu {
            if controller.activeRing != nil {
                Button("这一圈拍不了，跳过", systemImage: "forward") { controller.skipActiveRing() }
            }
            Button("重新选物体中心", systemImage: "scope") { controller.replaceAnchor() }
            if controller.depthSupported {
                Toggle("保存 LiDAR 深度", isOn: Binding(
                    get: { controller.depthEnabled },
                    set: { controller.setDepthEnabled($0) }
                ))
            }
            if controller.exposureLockAvailable {
                Toggle("锁定曝光/白平衡", isOn: Binding(
                    get: { controller.exposureLocked },
                    set: { controller.setExposureLocked($0) }
                ))
            }
            Button("使用说明", systemImage: "questionmark.circle") { onboardingDone = false }
            if controller.phase == .capturing, controller.shotCount > 0 {
                Button("现在就结束", systemImage: "checkmark") { close() }
            }
            Text(controller.videoFormatLabel + (controller.savedResolutionLabel.isEmpty ? "" : " · 已存 \(controller.savedResolutionLabel)"))
        } label: {
            Image(systemName: "ellipsis.circle.fill").font(.title).foregroundStyle(.white, .black.opacity(0.4))
        }
        .accessibilityLabel("更多")
    }
}

/// Big direction hint: arrow + short Chinese sentence.
struct GuidancePill: View {
    let hint: GuidanceHint?
    let keepGoing: Bool

    var body: some View {
        let c = content
        HStack(spacing: 10) {
            Image(systemName: c.symbol)
                .font(.title.bold())
                .symbolEffect(.pulse, isActive: c.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.title3.bold())
                if let s = c.subtitle { Text(s).font(.caption) }
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(c.color, in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: c.title)
    }

    private struct Content {
        var symbol: String
        var title: String
        var subtitle: String?
        var color: Color = .white
        var pulse = false
    }

    private var content: Content {
        guard let hint else { return Content(symbol: "hourglass", title: "准备中…") }
        if hint.isDone {
            return keepGoing
                ? Content(symbol: "plus.viewfinder", title: "可以继续补拍", subtitle: "走到灰色的位置会自动补拍", color: .green)
                : Content(symbol: "checkmark.circle.fill", title: "可以了", color: .green)
        }
        if hint.currentCell == nil {
            return Content(symbol: "scope", title: "把物体放回画面中间", color: .yellow)
        }
        if let v = hint.vertical {
            return v == .raise
                ? Content(symbol: "arrow.up", title: "把手机抬高一点", subtitle: hint.activeRing.map(CaptureStrings.ringHowTo), pulse: true)
                : Content(symbol: "arrow.down", title: "把手机放低一点", subtitle: hint.activeRing.map(CaptureStrings.ringHowTo), pulse: true)
        }
        if let h = hint.horizontal {
            let deg = Int((hint.degreesToTarget ?? 0).rounded())
            return h == .right
                ? Content(symbol: "arrow.right", title: "向右慢慢绕", subtitle: "到黄色那格还差 \(deg)°", pulse: true)
                : Content(symbol: "arrow.left", title: "向左慢慢绕", subtitle: "到黄色那格还差 \(deg)°", pulse: true)
        }
        if hint.currentCellIsNew {
            return Content(symbol: "camera.aperture", title: "稳住…", subtitle: "自动拍摄中", color: .yellow)
        }
        return Content(symbol: "arrow.triangle.2.circlepath", title: "继续慢慢绕")
    }
}

/// Shown when a ring is complete: what to do next, with a bobbing arrow.
struct RingDoneCard: View {
    let done: ElevationRing
    let next: ElevationRing
    let onSkip: () -> Void
    let onDismiss: () -> Void
    @State private var bob = false

    var body: some View {
        VStack(spacing: 10) {
            Text("✓ \(CaptureStrings.ringName(done))一圈完成").font(.headline).foregroundStyle(.green)
            Image(systemName: next.rawValue > done.rawValue ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .offset(y: bob ? (next.rawValue > done.rawValue ? -10 : 10) : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bob)
            Text(CaptureStrings.nextRingPrompt(next)).font(.title3.bold()).multilineTextAlignment(.center)
            Text(CaptureStrings.ringHowTo(next)).font(.caption)
            HStack {
                Button("知道了", action: onDismiss).buttonStyle(.borderedProminent).tint(.green)
                Button("这圈跳过", action: onSkip).buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
        .onAppear { bob = true }
    }
}

struct DoneCard: View {
    let shots: Int
    let onFinish: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(.green)
                .symbolEffect(.bounce, value: shots)
            Text("可以了！").font(.largeTitle.bold())
            Text("共 \(shots) 张，覆盖已经够训练用了").font(.subheadline)
            Button(action: onFinish) {
                Text("完成").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(.green)
            Button("继续补拍", action: onContinue).foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
        .padding(32)
    }
}
