import Foundation
import Observation
import SplattyCore

/// Asset library backed by `Documents/Splatty/<folder>/meta.json`.
@MainActor
@Observable
final class AssetStore {
    private(set) var assets: [AssetMeta] = []
    private(set) var lastError: String?
    /// Bumped whenever covers may have changed so thumbnails reload.
    private(set) var revision = 0
    let rootURL: URL

    init(rootURL: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? docs.appendingPathComponent(AssetLayout.libraryFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        reload()
    }

    func layout(for meta: AssetMeta) -> AssetLayout {
        AssetLayout(root: rootURL.appendingPathComponent(meta.folder, isDirectory: true))
    }

    func asset(id: String) -> AssetMeta? { assets.first { $0.id == id } }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        var loaded: [AssetMeta] = []
        for folder in folders {
            let metaURL = AssetLayout(root: folder).meta
            guard let data = try? Data(contentsOf: metaURL), var meta = try? AssetMeta.decode(data) else { continue }
            meta.folder = folder.lastPathComponent // trust the folder on disk
            loaded.append(meta)
        }
        let parser = ISO8601DateFormatter()
        assets = loaded.sorted {
            (parser.date(from: $0.createdAt) ?? .distantPast) > (parser.date(from: $1.createdAt) ?? .distantPast)
        }
        revision += 1
    }

    @discardableResult
    func create(name: String, category: AssetCategory) throws -> AssetMeta {
        let now = Date()
        let tz = TimeZone.current
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? category.rawValue.capitalized : trimmed
        var id = AssetNaming.shortID()
        while assets.contains(where: { $0.id == id }) { id = AssetNaming.shortID() }
        let folder = AssetNaming.folderName(date: now, timeZone: tz, name: displayName, category: category, shortID: id)
        let meta = AssetMeta(id: id, folder: folder, name: displayName, category: category,
                             createdAt: AssetNaming.iso8601(now, timeZone: tz), timeZone: tz.identifier)
        let layout = layout(for: meta)
        try FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try meta.jsonData().write(to: layout.meta, options: .atomic)
        reload()
        return meta
    }

    func update(_ meta: AssetMeta) {
        if let i = assets.firstIndex(where: { $0.id == meta.id }) {
            assets[i] = meta
            revision += 1
        }
    }

    func delete(_ meta: AssetMeta) {
        do {
            try FileManager.default.removeItem(at: layout(for: meta).root)
        } catch {
            lastError = "Delete failed: \(error.localizedDescription)"
        }
        reload()
    }

    /// Remove all shots of an asset (raw, depth, arkit, cover) and reset it to draft.
    func clearShots(_ meta: AssetMeta) throws -> AssetMeta {
        let layout = layout(for: meta)
        let fm = FileManager.default
        for url in [layout.raw, layout.depth, layout.arkit, layout.masks, layout.cover, layout.transforms, layout.log] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        var m = meta
        m.status = .draft
        m.counts = AssetCounts()
        m.capturedAt = nil
        try m.jsonData().write(to: layout.meta, options: .atomic)
        reload()
        return m
    }
}
