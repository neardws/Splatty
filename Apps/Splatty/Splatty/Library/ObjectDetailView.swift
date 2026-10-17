import SplattyCore
import SwiftUI

struct ObjectDetailView: View {
    let assetID: String
    @Environment(AssetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(CaptureSettings.Keys.planPreset) private var planPreset = CapturePlan.Preset.standard.rawValue
    @AppStorage(CaptureSettings.Keys.imageFormat) private var imageFormatRaw = ImageFormat.jpeg.rawValue
    @AppStorage(CaptureSettings.Keys.highResolution) private var highResolution = true
    @AppStorage(CaptureSettings.Keys.depth) private var depth = true

    @AppStorage(CaptureSettings.Keys.mode) private var modeRaw = CaptureMode.turntable.rawValue
    @AppStorage(CaptureSettings.Keys.voice) private var voice = true
    @State private var captureController: CaptureController?
    @State private var turntableController: TurntableCaptureController?
    @State private var confirmReshoot = false
    @State private var confirmDelete = false
    @State private var exportItem: ExportItem?
    @State private var exporting = false
    @State private var errorMessage: String?

    var body: some View {
        if let meta = store.asset(id: assetID) {
            content(meta)
        } else {
            ContentUnavailableView("找不到这个物体", systemImage: "questionmark.folder")
        }
    }

    @ViewBuilder
    private func content(_ meta: AssetMeta) -> some View {
        List {
            Section {
                CoverImage(url: store.layout(for: meta).cover, revision: store.revision)
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets())
            }
            Section("信息") {
                LabeledContent("类别", value: meta.category.label)
                LabeledContent("状态") { StatusBadge(status: meta.status) }
                LabeledContent("照片", value: "\(meta.counts.images)")
                LabeledContent("深度图", value: "\(meta.counts.depth)")
                LabeledContent("创建时间", value: meta.createdAt)
                if let c = meta.capturedAt { LabeledContent("最后拍摄", value: c) }
                if let d = meta.device { LabeledContent("设备", value: "\(d.identifier) · iOS \(d.systemVersion)") }
                LabeledContent("文件夹") { Text(meta.folder).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("拍摄") {
                Button {
                    if meta.counts.images > 0 { confirmReshoot = true } else { startCapture(meta) }
                } label: {
                    Label(meta.counts.images > 0 ? "重拍（会删除现有 \(meta.counts.images) 张）" : "开始拍摄",
                          systemImage: "camera.viewfinder")
                }
                Picker("拍摄方式", selection: $modeRaw) {
                    Text("转物体（桌面小物件）").tag(CaptureMode.turntable.rawValue)
                    Text("绕拍（大物件）").tag(CaptureMode.orbit.rawValue)
                }
                .pickerStyle(.inline)
                Text(modeRaw == CaptureMode.orbit.rawValue
                     ? "人绕着物体走一圈，适合放不上转盘的大物件。"
                     : "人坐着不动，手机对准物体，用手或转盘转物体。手机背面朝不朝向你都行，倒拿也可以。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("拍摄张数", selection: $planPreset) {
                    ForEach(CapturePlan.Preset.allCases) { p in
                        Text(modeRaw == CaptureMode.orbit.rawValue ? CaptureStrings.presetLabel(p) : CaptureStrings.turntablePresetLabel(p))
                            .tag(p.rawValue)
                    }
                }
                Toggle("语音提示（看不到屏幕时用）", isOn: $voice)
                Picker("图片格式", selection: $imageFormatRaw) {
                    ForEach(ImageFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
                }
                Toggle("高清照片", isOn: $highResolution)
                Toggle("保存 LiDAR 深度（如果有）", isOn: $depth)
            }
            Section("导出") {
                Button {
                    export(meta)
                } label: {
                    if exporting {
                        HStack { ProgressView(); Text("正在打包…") }
                    } else {
                        Label("分享 .zip（隔空投送到 Mac mini）", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(exporting || meta.counts.images == 0)
                Text("也可以在「文件」App → 我的 iPhone → Splatty 里找到。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("删除这个物体", role: .destructive) { confirmDelete = true }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle(meta.name)
        .fullScreenCover(item: $captureController, onDismiss: { store.reload() }) { controller in
            CaptureView(controller: controller)
        }
        .fullScreenCover(item: $turntableController, onDismiss: { store.reload() }) { controller in
            TurntableCaptureView(controller: controller)
        }
        .sheet(item: $exportItem) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("重拍会删除现有的 \(meta.counts.images) 张照片。", isPresented: $confirmReshoot,
                            titleVisibility: .visible) {
            Button("删除并重拍", role: .destructive) {
                do {
                    let cleared = try store.clearShots(meta)
                    startCapture(cleared)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog("删除「\(meta.name)」和它的所有文件？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.delete(meta)
                dismiss()
            }
        }
    }

    private func startCapture(_ meta: AssetMeta) {
        let settings = CaptureSettings.load()
        switch settings.mode {
        case .turntable:
            let controller = TurntableCaptureController(meta: meta, layout: store.layout(for: meta), settings: settings)
            controller.onMetaChanged = { [store] updated in store.update(updated) }
            turntableController = controller
        case .orbit:
            let controller = CaptureController(meta: meta, layout: store.layout(for: meta), settings: settings)
            controller.onMetaChanged = { [store] updated in store.update(updated) }
            captureController = controller
        }
    }

    private func export(_ meta: AssetMeta) {
        exporting = true
        errorMessage = nil
        let folder = store.layout(for: meta).root
        Task {
            do {
                let url = try await Exporter.zip(folder: folder)
                exportItem = ExportItem(url: url)
            } catch {
                errorMessage = "导出失败：\(error.localizedDescription)"
            }
            exporting = false
        }
    }
}

extension CaptureController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
