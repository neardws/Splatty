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
                Section("Name") {
                    TextField("e.g. Pikachu Gold / 皮卡丘", text: $name)
                        .textInputAutocapitalization(.words)
                }
                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(AssetCategory.allCases) { c in Text(c.label).tag(c) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Text("Folder: \(AssetNaming.folderName(date: Date(), timeZone: .current, name: name.isEmpty ? category.rawValue : name, category: category, shortID: "xxxxxx"))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, category)
                        dismiss()
                    }
                }
            }
        }
    }
}
