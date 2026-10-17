import Foundation
import SplattyCore

enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg, heic
    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : "heic" }
    var label: String { self == .jpeg ? "JPEG（兼容性最好）" : "HEIC（更小）" }
}

/// User-tunable capture settings (persisted with @AppStorage under these keys).
struct CaptureSettings: Sendable, Equatable {
    enum Keys {
        static let planPreset = "capture.planPreset"
        static let imageFormat = "capture.imageFormat"
        static let highResolution = "capture.highResolution"
        static let depth = "capture.depth"
        static let jpegQuality = "capture.jpegQuality"
    }

    var planPreset: CapturePlan.Preset = .standard
    var plan: CapturePlan { CapturePlan.preset(planPreset) }
    var imageFormat: ImageFormat = .jpeg
    var highResolution: Bool = true
    var depthEnabled: Bool = true
    var quality: Double = 0.92

    static func load(_ d: UserDefaults = .standard) -> CaptureSettings {
        var s = CaptureSettings()
        if let p = d.string(forKey: Keys.planPreset), let preset = CapturePlan.Preset(rawValue: p) { s.planPreset = preset }
        if let f = d.string(forKey: Keys.imageFormat), let fmt = ImageFormat(rawValue: f) { s.imageFormat = fmt }
        if d.object(forKey: Keys.highResolution) != nil { s.highResolution = d.bool(forKey: Keys.highResolution) }
        if d.object(forKey: Keys.depth) != nil { s.depthEnabled = d.bool(forKey: Keys.depth) }
        if d.object(forKey: Keys.jpegQuality) != nil { s.quality = min(1, max(0.5, d.double(forKey: Keys.jpegQuality))) }
        return s
    }
}
