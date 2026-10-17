import SplattyCore
import SwiftUI

struct ObjectDetailView: View {
    let assetID: String
    @Environment(AssetStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage(CaptureSettings.Keys.targetShots) private var targetShots = 120
    @AppStorage(CaptureSettings.Keys.imageFormat) private var imageFormatRaw = ImageFormat.jpeg.rawValue
    @AppStorage(CaptureSettings.Keys.highResolution) private var highResolution = true
    @AppStorage(CaptureSettings.Keys.depth) private var depth = true

    @State private var captureController: CaptureController?
    @State private var confirmReshoot = false
    @State private var confirmDelete = false
    @State private var exportItem: ExportItem?
    @State private var exporting = false
    @State private var errorMessage: String?

    var body: some View {
        if let meta = store.asset(id: assetID) {
            content(meta)
        } else {
            ContentUnavailableView("Object not found", systemImage: "questionmark.folder")
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
            Section("Info") {
                LabeledContent("Category", value: meta.category.label)
                LabeledContent("Status") { StatusBadge(status: meta.status) }
                LabeledContent("Views", value: "\(meta.counts.images)")
                LabeledContent("Depth maps", value: "\(meta.counts.depth)")
                LabeledContent("Created", value: meta.createdAt)
                if let c = meta.capturedAt { LabeledContent("Last shot", value: c) }
                if let d = meta.device { LabeledContent("Device", value: "\(d.identifier) · iOS \(d.systemVersion)") }
                LabeledContent("Folder") { Text(meta.folder).font(.caption.monospaced()).textSelection(.enabled) }
            }
            Section("Capture") {
                Button {
                    if meta.counts.images > 0 { confirmReshoot = true } else { startCapture(meta) }
                } label: {
                    Label(meta.counts.images > 0 ? "Re-shoot (clears \(meta.counts.images) views)" : "Start capture",
                          systemImage: "camera.viewfinder")
                }
                Stepper("Target views: \(targetShots)", value: $targetShots, in: 40...300, step: 10)
                Picker("Image format", selection: $imageFormatRaw) {
                    ForEach(ImageFormat.allCases) { f in Text(f.label).tag(f.rawValue) }
                }
                Toggle("High-res stills (captureHighResolutionFrame)", isOn: $highResolution)
                Toggle("Save LiDAR depth when available", isOn: $depth)
            }
            Section("Export") {
                Button {
                    export(meta)
                } label: {
                    if exporting {
                        HStack { ProgressView(); Text("Zipping…") }
                    } else {
                        Label("Share .zip (AirDrop to Mac mini)", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(exporting || meta.counts.images == 0)
                Text("Also visible in Files → On My iPhone → Splatty → Splatty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete object", role: .destructive) { confirmDelete = true }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle(meta.name)
        .fullScreenCover(item: $captureController, onDismiss: { store.reload() }) { controller in
            CaptureView(controller: controller)
        }
        .sheet(item: $exportItem) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("Re-shoot deletes the existing \(meta.counts.images) views.", isPresented: $confirmReshoot,
                            titleVisibility: .visible) {
            Button("Delete views and re-shoot", role: .destructive) {
                do {
                    let cleared = try store.clearShots(meta)
                    startCapture(cleared)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .confirmationDialog("Delete \(meta.name) and all its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(meta)
                dismiss()
            }
        }
    }

    private func startCapture(_ meta: AssetMeta) {
        let controller = CaptureController(meta: meta, layout: store.layout(for: meta), settings: .load())
        controller.onMetaChanged = { [store] updated in store.update(updated) }
        captureController = controller
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
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
            exporting = false
        }
    }
}

extension CaptureController: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
