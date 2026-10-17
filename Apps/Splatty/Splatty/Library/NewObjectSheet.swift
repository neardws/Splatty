import SplattyCore
import SwiftUI

struct NewObjectSheet: View {
    let onCreate: @MainActor (String, AssetCategory) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category: AssetCategory = .figure

    var body: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    TextField("例如：皮卡丘 / Pikachu Gold", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("类别") {
                    Picker("类别", selection: $category) {
                        ForEach(AssetCategory.allCases) { c in Text(c.label).tag(c) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text("文件夹：\(AssetNaming.folderName(date: Date(), timeZone: .current, name: name.isEmpty ? category.rawValue : name, category: category, shortID: "xxxxxx"))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建物体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(name, category)
                        dismiss()
                    }
                }
            }
        }
    }
}
