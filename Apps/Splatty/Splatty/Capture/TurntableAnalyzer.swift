@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation
import SplattyCore
@preconcurrency import Vision

/// Background image analysis for turntable mode (~10 Hz, one request in flight):
/// crops the object window, downsizes it to a small grayscale buffer, registers it
/// against the keyframe crop (Vision translational registration) and makes a 16×16
/// thumbnail for the change detector.
final class TurntableAnalyzer: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let image: CVPixelBuffer
        /// Crop window in image pixels (top-left origin).
        let crop: PixelRect
        let timestamp: Double
        /// Make the previous crop the keyframe before registering (tracker asked to re-key).
        let rekeyToPrevious: Bool
        /// Drop the keyframe (crop size changed, phase change...).
        let resetKey: Bool
    }

    struct Result: Sendable {
        /// Shift of the current crop vs the keyframe, full-resolution pixels (x right, y down).
        let shift: Vec2?
        /// True when this crop just became the keyframe (no shift to report).
        let fresh: Bool
        let thumbnail: [UInt8]
        let timestamp: Double
    }

    static let workSize = 256
    private let queue = DispatchQueue(label: "com.neardws.splatty.turntable.analyzer", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    // Analyzer-queue state.
    private var key: (buffer: CVPixelBuffer, cropWidth: Double)?
    private var previous: (buffer: CVPixelBuffer, cropWidth: Double)?

    func analyze(_ r: Request, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            completion(run(r))
        }
    }

    private func run(_ r: Request) -> Result {
        guard let small = cropToSmall(r.image, crop: r.crop) else {
            return Result(shift: nil, fresh: false, thumbnail: [], timestamp: r.timestamp)
        }
        let thumb = Self.thumbnail(small)
        if r.resetKey { key = nil }
        if r.rekeyToPrevious, let previous { key = previous }
        defer { previous = (small, r.crop.width) }
        guard let key, abs(key.cropWidth - r.crop.width) < 0.5 else {
            key = (small, r.crop.width)
            return Result(shift: nil, fresh: true, thumbnail: thumb, timestamp: r.timestamp)
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: small, options: [:])
        let handler = VNImageRequestHandler(cvPixelBuffer: key.buffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return Result(shift: nil, fresh: false, thumbnail: thumb, timestamp: r.timestamp)
        }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return Result(shift: nil, fresh: false, thumbnail: thumb, timestamp: r.timestamp)
        }
        // Checked on macOS with synthetic shifts: content moved by (+dx, +dy) in top-left
        // pixel coordinates gives tx = -dx, ty = +dy.
        let t = obs.alignmentTransform
        let scale = r.crop.width / Double(CVPixelBufferGetWidth(small))
        let shift = Vec2(-Double(t.tx) * scale, Double(t.ty) * scale)
        return Result(shift: shift, fresh: false, thumbnail: thumb, timestamp: r.timestamp)
    }

    /// Crop (top-left image pixels) → grayscale OneComponent8 buffer whose longer side is `workSize`.
    private func cropToSmall(_ image: CVPixelBuffer, crop: PixelRect) -> CVPixelBuffer? {
        let H = Double(CVPixelBufferGetHeight(image))
        guard crop.width >= 8, crop.height >= 8 else { return nil }
        let s = Double(Self.workSize) / max(crop.width, crop.height)
        let ow = max(8, Int((crop.width * s).rounded())), oh = max(8, Int((crop.height * s).rounded()))
        // Core Image uses a bottom-left origin.
        let ciRect = CGRect(x: crop.minX, y: H - crop.maxY, width: crop.width, height: crop.height)
        let img = CIImage(cvPixelBuffer: image)
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, ow, oh, kCVPixelFormatType_OneComponent8, attrs, &out) == kCVReturnSuccess,
              let out else { return nil }
        context.render(img, to: out, bounds: CGRect(x: 0, y: 0, width: ow, height: oh), colorSpace: nil)
        return out
    }

    /// 16×16 block-average thumbnail.
    static func thumbnail(_ b: CVPixelBuffer, size n: Int = 16) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), bpr = CVPixelBufferGetBytesPerRow(b)
        guard let base = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self), w >= n, h >= n else { return [] }
        var out = [UInt8](repeating: 0, count: n * n)
        for ty in 0..<n {
            for tx in 0..<n {
                let x0 = tx * w / n, x1 = (tx + 1) * w / n, y0 = ty * h / n, y1 = (ty + 1) * h / n
                var sum = 0, cnt = 0
                var y = y0
                while y < y1 {
                    var x = x0
                    while x < x1 { sum += Int(base[y * bpr + x]); cnt += 1; x += 2 }
                    y += 2
                }
                out[ty * n + tx] = UInt8(cnt > 0 ? sum / cnt : 0)
            }
        }
        return out
    }
}
