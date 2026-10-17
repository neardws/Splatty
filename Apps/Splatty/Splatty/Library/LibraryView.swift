import SplattyCore
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(AssetStore.self) private var store
    @State private var showingNew = false
    @State private var pendingDelete: AssetMeta?
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.assets.isEmpty {
                    ContentUnavailableView {
                        Label("还没有物体", systemImage: "cube.transparent")
                    } description: {
                        Text("新建一个物体，然后跟着提示绕它走一圈，大约 40 多张照片。")
                    } actions: {
                        Button("新建物体") { showingNew = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(store.assets) { meta in
                            NavigationLink(value: meta.id) {
                                AssetRow(meta: meta, coverURL: store.layout(for: meta).cover, revision: store.revision)
                            }
                            .swipeActions {
                                Button(role: .destructive) { pendingDelete = meta } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .refreshable { store.reload() }
                }
            }
            .navigationTitle("Splatty")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNew = true } label: { Label("新建物体", systemImage: "plus") }
                }
            }
            .navigationDestination(for: String.self) { id in
                ObjectDetailView(assetID: id)
            }
            .sheet(isPresented: $showingNew) {
                NewObjectSheet { name, category in
                    do {
                        let meta = try store.create(name: name, category: category)
                        path.append(meta.id)
                    } catch {
                        // Surface via store error banner on next render.
                    }
                }
            }
            .confirmationDialog(
                "删除「\(pendingDelete?.name ?? "")」？",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("删除物体和全部照片", role: .destructive) {
                    if let m = pendingDelete { store.delete(m) }
                    pendingDelete = nil
                }
            }
            .onAppear { store.reload() }
        }
    }
}

struct AssetRow: View {
    let meta: AssetMeta
    let coverURL: URL
    let revision: Int

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: coverURL, revision: revision)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.name).font(.headline)
                Text(meta.category.label).font(.caption).foregroundStyle(.secondary)
                Text("\(meta.counts.images) 张" + (meta.counts.depth > 0 ? " · \(meta.counts.depth) 深度" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: meta.status)
        }
    }
}

struct CoverImage: View {
    let url: URL
    let revision: Int

    var body: some View {
        if let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "camera.viewfinder").foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let status: AssetStatus

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .draft: "未拍"
        case .captured: "已拍"
        case .processing: "训练中"
        case .ready: "完成"
        case .failed: "失败"
        }
    }

    private var color: Color {
        switch status {
        case .draft: .gray
        case .captured: .blue
        case .processing: .orange
        case .ready: .green
        case .failed: .red
        }
    }
}
