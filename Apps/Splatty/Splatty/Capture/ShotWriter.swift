@preconcurrency import ARKit
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import ImageIO
import SplattyCore
import UniformTypeIdentifiers

/// Everything needed to write one shot, extracted from an `ARFrame` so the
/// frame itself is never retained.
struct ShotPayload: @unchecked Sendable {
    let index: Int
    let image: CVPixelBuffer
    let pose: Mat4
    let intrinsics: Intrinsics
    let timestamp: Double
    let capturedAt: String
    let exposureDuration: Double
    let exposureOffset: Double
    let ambientIntensity: Double?
    let ambientColorTemperature: Double?
    let tracking: TrackingQuality
    let highResolution: Bool
    let depth: DepthSource?
    /// Turntable mode: normalized (0–1, top-left origin) image position of the object
    /// centre, used to pick the right subject when generating the mask.
    var maskHint: CGPoint?
    /// ARKit feature points (world space) visible at trigger time.
    private(set) var featurePoints: [Vec3]

    /// Depth taken from a (possibly different) streaming frame, with that frame's pose.
    struct DepthSource: @unchecked Sendable {
        let depth: CVPixelBuffer
        let confidence: CVPixelBuffer?
        let timestamp: Double
        let pose: Mat4
        /// Camera intrinsics scaled to the depth map size.
        let intrinsics: Intrinsics

        init?(frame: ARFrame) {
            guard let d = frame.sceneDepth else { return nil }
            depth = d.depthMap
            confidence = d.confidenceMap
            timestamp = frame.timestamp
            pose = Mat4(frame.camera.transform)
            intrinsics = Intrinsics(frame.camera).scaled(
                toWidth: CVPixelBufferGetWidth(d.depthMap), height: CVPixelBufferGetHeight(d.depthMap))
        }
    }

    /// Streaming-frame image + metadata kept as a fallback if a high-res still fails.
    struct StreamSource: @unchecked Sendable {
        let image: CVPixelBuffer
        let pose: Mat4
        let intrinsics: Intrinsics
        let timestamp: Double
        let exposureDuration: Double
        let exposureOffset: Double
        let ambientIntensity: Double?
        let ambientColorTemperature: Double?
        let tracking: TrackingQuality
        let featurePoints: [Vec3]

        init(frame: ARFrame) {
            image = frame.capturedImage
            pose = Mat4(frame.camera.transform)
            let w = CVPixelBufferGetWidth(frame.capturedImage)
            let h = CVPixelBufferGetHeight(frame.capturedImage)
            intrinsics = Intrinsics(frame.camera).scaled(toWidth: w, height: h)
            timestamp = frame.timestamp
            exposureDuration = frame.camera.exposureDuration
            exposureOffset = Double(frame.camera.exposureOffset)
            ambientIntensity = frame.lightEstimate.map { Double($0.ambientIntensity) }
            ambientColorTemperature = frame.lightEstimate.map { Double($0.ambientColorTemperature) }
            tracking = TrackingQuality(frame.camera.trackingState)
            featurePoints = (frame.rawFeaturePoints?.points ?? []).map { Vec3($0) }
        }
    }

    init(index: Int, stream s: StreamSource, depth: DepthSource?, capturedAt: String, highResolution: Bool = false) {
        self.index = index
        image = s.image
        pose = s.pose
        intrinsics = s.intrinsics
        timestamp = s.timestamp
        self.capturedAt = capturedAt
        exposureDuration = s.exposureDuration
        exposureOffset = s.exposureOffset
        ambientIntensity = s.ambientIntensity
        ambientColorTemperature = s.ambientColorTemperature
        tracking = s.tracking
        self.highResolution = highResolution
        self.depth = depth
        featurePoints = s.featurePoints
    }

    /// From a high-resolution still. Uses its own scene depth if ARKit attached
    /// one, otherwise `fallbackDepth` from the streaming frame at trigger time.
    init(index: Int, highResFrame f: ARFrame, includeDepth: Bool, fallbackDepth: DepthSource?,
         fallbackFeatures: [Vec3], capturedAt: String) {
        let s = StreamSource(frame: f)
        let own = includeDepth ? DepthSource(frame: f) : nil
        self.init(index: index, stream: s, depth: includeDepth ? (own ?? fallbackDepth) : nil,
                  capturedAt: capturedAt, highResolution: true)
        if featurePoints.isEmpty { featurePoints = fallbackFeatures }
    }
}

struct ShotWriteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Serial background writer for images, depth maps and JSON.
final class ShotWriter: @unchecked Sendable {
    let layout: AssetLayout
    let format: ImageFormat
    let quality: Double
    private let queue = DispatchQueue(label: "com.neardws.splatty.shotwriter", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Seed points; only touched on `queue`.
    private var cloud = PointCloudAccumulator()
    let mode: CaptureMode

    init(layout: AssetLayout, format: ImageFormat, quality: Double, mode: CaptureMode = .orbit) {
        self.layout = layout
        self.format = format
        self.quality = quality
        self.mode = mode
    }

    func prepareDirectories() throws {
        let fm = FileManager.default
        let dirs = mode == .turntable ? [layout.raw, layout.depth, layout.masks] : [layout.raw, layout.depth, layout.arkit]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func write(_ p: ShotPayload, completion: @escaping @Sendable (Result<FrameRecord, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try writeSync(p).0 })
        }
    }

    /// Writes arkit/points3D.ply (orbit only), transforms.json, meta.json and capture_log.json.
    /// Each file has its own try/catch: one failing file (e.g. a NaN in transforms.json, which
    /// is what lost the 2026-10-17 pilot's metadata) must not stop the others.
    func persist(frames: [FrameRecord], anchor: Vec3?, meta: AssetMeta, log: CaptureLog?,
                 completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            var firstError: Error?
            var log = log
            func note(_ what: String, _ error: Error) {
                if firstError == nil { firstError = ShotWriteError(message: "\(what): \(error.localizedDescription)") }
                log?.add("error", "\(what): \(error)", t: -1)
            }
            let hasPoints = mode == .orbit && cloud.count > 0
            if hasPoints {
                do { try PLYWriter.binary(cloud.points).write(to: layout.points, options: .atomic) } catch { note("points3D.ply", error) }
            }
            do {
                if let doc = TransformsDocument.make(frames: frames, objectAnchor: mode == .orbit ? anchor : nil,
                                                     plyFilePath: hasPoints ? AssetLayout.relativePointsPath : nil,
                                                     captureMode: mode, maskSource: MaskInfo.visionPreliminary) {
                    try doc.jsonData().write(to: layout.transforms, options: .atomic)
                }
            } catch { note("transforms.json", error) }
            do { try meta.jsonData().write(to: layout.meta, options: .atomic) } catch { note("meta.json", error) }
            if let log {
                do { try log.jsonData().write(to: layout.log, options: .atomic) } catch { firstError = firstError ?? error }
            }
            completion(firstError)
        }
    }

    // MARK: - Sync work (writer queue)

    /// Turntable: also returns the subject box of the saved mask (normalized, top-left origin).
    func writeWithMask(_ p: ShotPayload, completion: @escaping @Sendable (Result<(FrameRecord, CGRect?), Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try writeSync(p) })
        }
    }

    private func writeSync(_ p: ShotPayload) throws -> (FrameRecord, CGRect?) {
        let image = CIImage(cvPixelBuffer: p.image)
        let data: Data?
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        switch format {
        case .jpeg: data = context.jpegRepresentation(of: image, colorSpace: sRGB, options: opts)
        case .heic: data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: sRGB, options: opts)
        }
        guard let data else { throw ShotWriteError(message: "Image encoding failed") }
        try data.write(to: layout.imageURL(index: p.index, ext: format.fileExtension), options: .atomic)

        var depthPath: String?
        var confPath: String?
        if let d = p.depth {
            let (w, h, meters) = try Self.readDepth(d.depth)
            if mode == .turntable {
                // Depth is camera-relative and still valid per frame; the world-space seed
                // cloud is not (the object turns), so we skip it.
                try Self.writeDepthPNG(meters: meters, width: w, height: h, to: layout.depthURL(index: p.index))
                depthPath = AssetLayout.relativeDepthPath(index: p.index)
                if let c = d.confidence {
                    let (cw, ch, bytes) = try Self.readConfidence(c)
                    try Self.writeConfidencePNG(bytes: bytes, width: cw, height: ch, to: layout.confidenceURL(index: p.index))
                    confPath = AssetLayout.relativeConfidencePath(index: p.index)
                }
            } else {
                try Self.writeDepthPNG(meters: meters, width: w, height: h, to: layout.depthURL(index: p.index))
                depthPath = AssetLayout.relativeDepthPath(index: p.index)
                var conf: [UInt8]?
                if let c = d.confidence {
                    let (cw, ch, bytes) = try Self.readConfidence(c)
                    try Self.writeConfidencePNG(bytes: bytes, width: cw, height: ch, to: layout.confidenceURL(index: p.index))
                    confPath = AssetLayout.relativeConfidencePath(index: p.index)
                    conf = (cw == w && ch == h) ? bytes : nil
                }
                let samples = DepthSampler.samples(depth: meters, confidence: conf, width: w, height: h,
                                                   intrinsics: d.intrinsics, cameraToWorld: d.pose)
                let colors = Self.sampleColors(p.image, at: samples.map { ($0.u, $0.v) }, sourceWidth: w, sourceHeight: h)
                for (s, c) in zip(samples, colors) {
                    cloud.add(ColoredPoint(s.world, r: c.0, g: c.1, b: c.2))
                }
            }
        }
        if mode == .orbit {
            for fp in p.featurePoints { cloud.add(ColoredPoint(fp)) }
        }

        // Turntable: foreground mask in COLMAP naming. A failed mask never fails the shot.
        var maskPath: String?
        var maskBox: CGRect?
        if mode == .turntable {
            let url = layout.maskURL(index: p.index, imageExt: format.fileExtension)
            if let result = try? SubjectMasker.writeMask(for: p.image, hint: p.maskHint, to: url, context: context) {
                maskPath = AssetLayout.relativeMaskPath(index: p.index, imageExt: format.fileExtension)
                maskBox = result
            }
        }

        if !FileManager.default.fileExists(atPath: layout.cover.path) {
            writeCover(image)
        }

        var record = FrameRecord(
            index: p.index,
            filePath: AssetLayout.relativeImagePath(index: p.index, ext: format.fileExtension),
            depthFilePath: depthPath,
            confidenceFilePath: confPath,
            transform: CameraConvention.arkitToNerfstudio(p.pose),
            intrinsics: p.intrinsics,
            timestamp: p.timestamp,
            capturedAt: p.capturedAt,
            exposureDuration: p.exposureDuration,
            exposureOffset: p.exposureOffset,
            ambientIntensity: p.ambientIntensity,
            ambientColorTemperature: p.ambientColorTemperature,
            tracking: p.tracking.label,
            highResolution: p.highResolution,
            depthTimestamp: p.depth?.timestamp
        )
        record.poseValid = mode.arkitPosesAreObjectPoses
        record.maskFilePath = maskPath
        return (record, maskBox)
    }

    /// Portrait-rotated ~480 px cover for the library list.
    private func writeCover(_ image: CIImage) {
        let rotated = image.oriented(.right)
        let extent = rotated.extent
        guard extent.width > 0 else { return }
        let scale = 480 / extent.width
        let small = rotated
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8,
        ]
        if let data = context.jpegRepresentation(of: small, colorSpace: sRGB, options: opts) {
            try? data.write(to: layout.cover, options: .atomic)
        }
    }

    // MARK: - Depth / confidence PNGs

    /// Copies a Float32 depth map (metres) into a row-major array.
    static func readDepth(_ buffer: CVPixelBuffer) throws -> (Int, Int, [Float]) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else {
            throw ShotWriteError(message: "Unexpected depth pixel format")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ShotWriteError(message: "No depth data") }
        var meters = [Float]()
        meters.reserveCapacity(w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { meters.append(row[x]) }
        }
        return (w, h, meters)
    }

    /// Copies an ARConfidenceLevel map (UInt8 0=low, 1=medium, 2=high).
    static func readConfidence(_ buffer: CVPixelBuffer) throws -> (Int, Int, [UInt8]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ShotWriteError(message: "No confidence data") }
        var bytes = [UInt8]()
        bytes.reserveCapacity(w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { bytes.append(row[x]) }
        }
        return (w, h, bytes)
    }

    /// Metres → 16-bit grayscale PNG in millimetres.
    static func writeDepthPNG(meters: [Float], width: Int, height: Int, to url: URL) throws {
        let mm = DepthEncoding.millimeters(fromMeters: meters)
        let data = mm.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        try writeGrayPNG(data: data, width: width, height: height, bitsPerComponent: 16, bitmapInfo: info, to: url)
    }

    /// Raw confidence values (0/1/2) → 8-bit grayscale PNG.
    static func writeConfidencePNG(bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        try writeGrayPNG(data: Data(bytes), width: width, height: height, bitsPerComponent: 8, bitmapInfo: info, to: url)
    }

    /// Samples RGB from a 420 bi-planar YCbCr image at depth-map pixel positions
    /// (depth and colour share the same field of view). Gray if the format is unexpected.
    static func sampleColors(_ image: CVPixelBuffer, at points: [(Int, Int)], sourceWidth: Int, sourceHeight: Int)
        -> [(UInt8, UInt8, UInt8)] {
        let gray: (UInt8, UInt8, UInt8) = (128, 128, 128)
        let format = CVPixelBufferGetPixelFormatType(image)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(image) >= 2, sourceWidth > 0, sourceHeight > 0 else {
            return points.map { _ in gray }
        }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return points.map { _ in gray } }
        let w = CVPixelBufferGetWidthOfPlane(image, 0)
        let h = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)
        return points.map { pt in
            let u = pt.0, v = pt.1
            let x = min(w - 1, max(0, Int((Double(u) + 0.5) / Double(sourceWidth) * Double(w))))
            let y = min(h - 1, max(0, Int((Double(v) + 0.5) / Double(sourceHeight) * Double(h))))
            let yy = yPtr[y * yRow + x]
            let ci = (y / 2) * cRow + (x / 2) * 2
            return ColorConversion.rgb(y: yy, cb: cPtr[ci], cr: cPtr[ci + 1])
        }
    }

    private static func writeGrayPNG(data: Data, width: Int, height: Int, bitsPerComponent: Int,
                                     bitmapInfo: CGBitmapInfo, to url: URL) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: bitsPerComponent,
                  bitsPerPixel: bitsPerComponent,
                  bytesPerRow: width * bitsPerComponent / 8,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ShotWriteError(message: "PNG setup failed") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ShotWriteError(message: "PNG write failed") }
    }
}
