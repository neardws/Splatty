import Foundation
import SwiftUI
import UIKit

enum Exporter {
    /// Zips a folder using `NSFileCoordinator`'s `.forUploading` option
    /// (system-provided zip, no third-party code). Returns a URL in tmp/.
    static func zip(folder: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try zipSync(folder: folder)
        }.value
    }

    static func zipSync(folder: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(folder.lastPathComponent).zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                // The system zip is deleted when this block returns, so copy it out.
                try FileManager.default.copyItem(at: zipURL, to: dest)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return dest
    }
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController wrapper (AirDrop, Files, …).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
