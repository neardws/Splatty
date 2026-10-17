@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Vision

/// On-device foreground masks via Vision subject lifting
/// (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+). Runs on the writer / analysis
/// queues, never on the main thread. These are "vision_preliminary" masks: good enough to
/// keep the static background out of COLMAP; the Mac may redo them with BiRefNet / SAM 2.
enum SubjectMasker {
    struct Detection: @unchecked Sendable {
        /// Low-resolution float mask (1 = subject) of the chosen instance(s).
        let mask: CVPixelBuffer
        /// Subject box, normalized 0–1, top-left origin, in the input image.
        let box: CGRect
    }

    /// `hint`: normalized (top-left origin) point on the object we care about; picks the
    /// instance under it (or the nearest one). nil → all instances.
    static func detect(_ image: CVPixelBuffer, hint: CGPoint?) throws -> Detection? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }

        let labels = obs.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
        let bpr = CVPixelBufferGetBytesPerRow(labels)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(labels)?.assumingMemoryBound(to: UInt8.self) else { return nil }

        var chosen = obs.allInstances
        if let hint {
            let hx = min(w - 1, max(0, Int(hint.x * CGFloat(w))))
            let hy = min(h - 1, max(0, Int(hint.y * CGFloat(h))))
            let under = Int(base[hy * bpr + hx])
            if under != 0 {
                chosen = IndexSet(integer: under)
            } else {
                // Nearest instance centroid to the hint.
                var sums: [Int: (x: Double, y: Double, n: Double)] = [:]
                for y in stride(from: 0, to: h, by: 2) {
                    for x in stride(from: 0, to: w, by: 2) {
                        let l = Int(base[y * bpr + x])
                        if l != 0 {
                            let s = sums[l] ?? (0, 0, 0)
                            sums[l] = (s.x + Double(x), s.y + Double(y), s.n + 1)
                        }
                    }
                }
                if let best = sums.min(by: { a, b in
                    hypot(a.value.x / a.value.n - Double(hx), a.value.y / a.value.n - Double(hy))
                        < hypot(b.value.x / b.value.n - Double(hx), b.value.y / b.value.n - Double(hy))
                }) {
                    chosen = IndexSet(integer: best.key)
                }
            }
        }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            for x in 0..<w where chosen.contains(Int(row[x])) {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                         width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h))
        let mask = try obs.generateMask(forInstances: chosen)
        return Detection(mask: mask, box: box)
    }

    /// Writes an 8-bit PNG mask at the image's full resolution (COLMAP needs the same size):
    /// 255 = object (keep), 0 = background (ignore). Returns the subject box.
    static func writeMask(for image: CVPixelBuffer, hint: CGPoint?, to url: URL, context: CIContext) throws -> CGRect? {
        guard let d = try detect(image, hint: hint) else { return nil }
        let W = CGFloat(CVPixelBufferGetWidth(image)), H = CGFloat(CVPixelBufferGetHeight(image))
        let mw = CGFloat(CVPixelBufferGetWidth(d.mask)), mh = CGFloat(CVPixelBufferGetHeight(d.mask))
        guard mw > 0, mh > 0 else { return nil }
        let full = CIImage(cvPixelBuffer: d.mask)
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: W / mw, y: H / mh))
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray),
              let png = context.pngRepresentation(of: full, format: .L8, colorSpace: gray) else { return nil }
        try png.write(to: url, options: .atomic)
        return d.box
    }
}
