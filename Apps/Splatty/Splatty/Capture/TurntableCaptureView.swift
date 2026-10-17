import SplattyCore
import SwiftUI

/// Turntable capture screen. Everything readable from ~50 cm: big type, high contrast,
/// and the whole overlay turns with the phone (portrait, landscape, upside-down).
struct TurntableCaptureView: View {
    @State var controller: TurntableCaptureController
    @Environment(\.dismiss) private var dismiss
    @State private var flash = false

    var body: some View {
        ZStack {
            ARCaptureView(host: controller)
                .ignoresSafeArea()

            if let r = controller.roiViewRect, controller.phase == .capturing {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(controller.issue == .objectOutOfView ? .red : .yellow, lineWidth: 3)
                        .frame(width: r.width * geo.size.width, height: r.height * geo.size.height)
                        .position(x: r.midX * geo.size.width, y: r.midY * geo.size.height)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if flash {
                Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            }

            RotatingContainer(degrees: controller.uiRotation) {
                switch controller.phase {
                case .tips:
                    TurntableTipsCard(onStart: { controller.finishTips() }, onClose: close)
                case .placing:
                    placingOverlay
                case .capturing:
                    capturingOverlay
                case .done:
                    ZStack {
                        capturingOverlay
                        if !controller.keepGoing {
                            DoneCard(shots: controller.shotCount, onFinish: close,
                                     onContinue: { controller.continueShooting() })
                        }
                    }
                }
            }
        }
        .animation(.spring(duration: 0.35), value: controller.phase)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
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

    // MARK: Placing

    private var placingOverlay: some View {
        VStack {
            HStack { closeButton; Spacer() }
            Spacer()
            ZStack {
                Circle().stroke(.white, lineWidth: 3).frame(width: 90, height: 90)
                Circle().fill(.yellow).frame(width: 10, height: 10)
            }
            .allowsHitTesting(false)
            Spacer()
            VStack(spacing: 12) {
                Text("把物体放在画面中间，点一下它").font(.title2.bold())
                Text("物体占画面一半左右 · 手机离物体 25–40 厘米").font(.headline)
                if !controller.trackingText.isEmpty {
                    Text(controller.trackingText).font(.subheadline).foregroundStyle(.yellow)
                }
                if let e = controller.lastError {
                    Text(e).font(.subheadline).foregroundStyle(.yellow)
                }
                Button { controller.tapCenter() } label: {
                    Text("就是中间这个").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.green)
                .disabled(!controller.trackingIsNormal)
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
        }
        .padding()
    }

    // MARK: Capturing

    private var capturingOverlay: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                closeButton
                Spacer()
                ringTitle
                Spacer()
                moreMenu
            }
            statusBanner
            if let done = controller.completedRing, let next = controller.activeRing {
                TurntableRingDoneCard(done: done, next: next,
                                      onDismiss: { controller.dismissRingCard() },
                                      onSkip: { controller.skipActiveRing() })
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                TurntableDial(bins: controller.activeRing.map { controller.coverage.coveredBins($0) } ?? [],
                              angle: controller.ringAngle,
                              showNeedle: controller.activeRing != .top && controller.rotationReliable,
                              count: controller.shotCount, target: controller.targetShots)
                    .frame(width: 190, height: 190)
                Spacer()
            }
            .overlay(alignment: .bottomTrailing) { shutterButton }
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: controller.issue)
        .animation(.spring(duration: 0.35), value: controller.completedRing)
    }

    private var ringTitle: some View {
        VStack(spacing: 2) {
            if let r = controller.activeRing {
                Text("第 \((controller.plan.order.firstIndex(of: r) ?? 0) + 1)/\(controller.plan.order.count) 圈 · \(TurntableStrings.ringName(r))")
                    .font(.title3.bold())
                Text(TurntableStrings.ringHowTo(r)).font(.subheadline)
            } else {
                Text("全部完成").font(.title3.bold())
            }
            if let e = controller.elevation {
                Text("手机高度 \(Int(e.rounded()))°").font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The one big sentence: what to do right now.
    private var statusBanner: some View {
        let s = TurntableStrings.status(issue: controller.issue, ring: controller.activeRing,
                                        reliable: controller.rotationReliable, speed: controller.turnSpeed,
                                        trackingText: controller.trackingText)
        return HStack(spacing: 12) {
            Image(systemName: s.symbol).font(.system(size: 34, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.system(size: 30, weight: .heavy))
                if let sub = s.subtitle { Text(sub).font(.headline) }
            }
        }
        .foregroundStyle(s.color == .red ? .white : .black)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(s.color, in: Capsule())
    }

    private var shutterButton: some View {
        Button { controller.shutter() } label: {
            ZStack {
                Circle().fill(.white.opacity(0.9)).frame(width: 60, height: 60)
                if controller.isSaving { ProgressView() } else {
                    Image(systemName: "camera.fill").font(.title2).foregroundStyle(.black)
                }
            }
        }
        .disabled(controller.isSaving)
        .accessibilityLabel("手动拍一张")
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark.circle.fill").font(.system(size: 34)).foregroundStyle(.white, .black.opacity(0.5))
        }
        .accessibilityLabel("关闭")
    }

    private var moreMenu: some View {
        Menu {
            Toggle(isOn: $controller.voiceEnabled) { Label("语音提示", systemImage: "speaker.wave.2") }
            if controller.activeRing != nil {
                Button("这一圈跳过", systemImage: "forward") { controller.skipActiveRing() }
            }
            Button("重新点选物体", systemImage: "scope") { controller.replaceAnchor() }
            if controller.shotCount > 0 {
                Button("现在就结束（已拍 \(controller.shotCount) 张）", systemImage: "checkmark") { close() }
            }
            if let e = controller.lastError { Text(e) }
        } label: {
            Image(systemName: "ellipsis.circle.fill").font(.system(size: 34)).foregroundStyle(.white, .black.opacity(0.5))
        }
        .accessibilityLabel("更多")
    }
}

/// Lays out portrait-locked content as if the screen were rotated by `degrees` (clockwise).
struct RotatingContainer<Content: View>: View {
    let degrees: Int
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let sideways = degrees == 90 || degrees == -90
            content
                .frame(width: sideways ? geo.size.height : geo.size.width,
                       height: sideways ? geo.size.width : geo.size.height)
                .rotationEffect(.degrees(Double(degrees)))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .animation(.easeInOut(duration: 0.3), value: degrees)
    }
}

/// Coverage dial of the object's own rotation: green = shot, grey = still needed,
/// white needle = estimated current angle. Big count in the middle.
struct TurntableDial: View {
    let bins: [Bool]
    let angle: Double
    let showNeedle: Bool
    let count: Int
    let target: Int

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.6))
            let n = max(1, bins.count)
            ForEach(0..<n, id: \.self) { i in
                let gap = n > 1 ? 0.012 : 0
                Circle()
                    .trim(from: Double(i) / Double(n) + gap, to: Double(i + 1) / Double(n) - gap)
                    .stroke(bins.indices.contains(i) && bins[i] ? Color.green : Color.white.opacity(0.3),
                            style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .padding(14)
            }
            if showNeedle {
                Capsule().fill(.white).frame(width: 6, height: 34)
                    .offset(y: -66)
                    .rotationEffect(.degrees(angle))
            }
            VStack(spacing: 0) {
                Text("\(count)").font(.system(size: 52, weight: .heavy, design: .rounded)).monospacedDigit()
                Text("/ \(target) 张").font(.headline)
            }
            .foregroundStyle(.white)
        }
    }
}

struct TurntableRingDoneCard: View {
    let done: TurntableRing
    let next: TurntableRing
    let onDismiss: () -> Void
    let onSkip: () -> Void
    @State private var bob = false

    var body: some View {
        VStack(spacing: 10) {
            Text("✓ \(TurntableStrings.ringName(done))这一圈完成").font(.title3.bold()).foregroundStyle(.green)
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 48)).foregroundStyle(.yellow)
                .offset(y: bob ? -10 : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bob)
            Text(TurntableStrings.nextRingPrompt(next)).font(.title2.bold()).multilineTextAlignment(.center)
            HStack {
                Button("知道了", action: onDismiss).buttonStyle(.borderedProminent).tint(.green)
                Button("这圈跳过", action: onSkip).buttonStyle(.bordered).tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
        .onAppear { bob = true }
    }
}

/// ~10 s of setup tips before the first tap; auto-continues.
struct TurntableTipsCard: View {
    let onStart: () -> Void
    let onClose: () -> Void
    @State private var remaining = 10

    private let tips: [(String, String, String)] = [
        ("square.stack.3d.down.right", "垫一张有花纹的纸",
         "物体放在转盘或一张杂志/报纸上，纸跟着物体一起转。想拍低角度，就先用杯子或小盒子把物体垫高。"),
        ("sun.haze", "柔和的光",
         "阴天的窗边，或台灯打到白墙上反射。不要开闪光灯/手电，避免硬阴影（阴影会跟着物体转）。"),
        ("iphone.gen3", "手机不动，转物体",
         "手机拿稳（有支架更好），对准物体。转一点、停一下，听到轻震就继续。"),
        ("rectangle.dashed", "背景简单",
         "背后是纯色墙或纸，别有其他东西在动。"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text("转物体拍摄 · 开始前").font(.title2.bold())
            VStack(alignment: .leading, spacing: 14) {
                ForEach(tips.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: tips[i].0).font(.title2).foregroundStyle(.green).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tips[i].1).font(.headline)
                            Text(tips[i].2).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(action: onStart) {
                Text(remaining > 0 ? "准备好了（\(remaining)）" : "准备好了")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).tint(.green)
        }
        .padding(22)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(20)
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            onStart()
        }
    }
}

/// Chinese strings for turntable mode.
enum TurntableStrings {
    static func ringName(_ r: TurntableRing) -> String {
        switch r {
        case .eye: "平视"
        case .high: "斜上方"
        case .top: "正上方"
        }
    }

    static func ringHowTo(_ r: TurntableRing) -> String {
        switch r {
        case .eye: "手机和物体差不多高，略高一点"
        case .high: "手机抬高，从斜上方 45° 往下看"
        case .top: "手机在物体正上方往下拍"
        }
    }

    static func nextRingPrompt(_ r: TurntableRing) -> String {
        switch r {
        case .eye: "回到平视高度再转一圈"
        case .high: "抬高手机，开始下一圈"
        case .top: "手机举到正上方往下拍，每拍一张把物体转 1/3 圈"
        }
    }

    struct Status {
        var symbol: String
        var title: String
        var subtitle: String?
        var color: Color
    }

    static func status(issue: TurntableIssue?, ring: TurntableRing?, reliable: Bool, speed: Double,
                       trackingText: String) -> Status {
        guard let ring else { return Status(symbol: "checkmark.circle.fill", title: "可以了", color: .green) }
        if let issue {
            switch issue {
            case .tracking:
                return Status(symbol: "exclamationmark.triangle.fill", title: "跟踪不稳", subtitle: trackingText, color: .orange)
            case .objectOutOfView:
                return Status(symbol: "scope", title: "对准物体", subtitle: "让物体回到画面中间", color: .red)
            case .wrongHeight(.raise):
                return Status(symbol: "arrow.up", title: "手机抬高一点", subtitle: ringHowTo(ring), color: .yellow)
            case .wrongHeight(.lower):
                return Status(symbol: "arrow.down", title: "手机放低一点", subtitle: ringHowTo(ring), color: .yellow)
            case .tooDark:
                return Status(symbol: "lightbulb.max", title: "太暗了", subtitle: "开灯或靠近窗边", color: .red)
            case .phoneMoving:
                return Status(symbol: "iphone.gen3.radiowaves.left.and.right", title: "手机别动", subtitle: "只转物体", color: .red)
            case .turningTooFast:
                return Status(symbol: "tortoise.fill", title: "太快了", subtitle: "慢一点转", color: .red)
            case .holdStill:
                return Status(symbol: "hand.raised.fill", title: "停一下", subtitle: "等它拍完", color: .yellow)
            }
        }
        if ring == .top {
            return Status(symbol: "arrow.down.to.line", title: "从正上方拍", subtitle: "每拍一张，把物体转 1/3 圈", color: .white)
        }
        if !reliable {
            return Status(symbol: "arrow.triangle.2.circlepath", title: "转一点，停一下",
                          subtitle: "画面变化够大就会自动拍", color: .white)
        }
        return Status(symbol: "arrow.triangle.2.circlepath", title: speed > 3 ? "继续慢慢转" : "慢慢转物体",
                      subtitle: "转一点停一下，听到轻震继续", color: .white)
    }
}
