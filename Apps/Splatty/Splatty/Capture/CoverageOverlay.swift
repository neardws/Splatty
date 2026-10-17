import SplattyCore
import SwiftUI

/// 2D dial: three concentric rings (outer = low, inner = high), one arc per azimuth bin.
/// Green = covered, grey = needed, yellow = next target, white = where you are now.
/// The active ring is drawn thicker; other rings are dimmed.
struct CoverageRingsView: View {
    let coverage: CoverageMap
    let current: CoverageCell?
    let activeRing: ElevationRing?
    let targetBin: Int?
    let skipped: Set<ElevationRing>

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2 - 4
            let band = maxR / 3.4
            for ring in ElevationRing.allCases {
                let isActive = ring == activeRing
                let lineWidth = band * (isActive ? 0.8 : 0.5)
                // low → outer
                let radius = maxR - CGFloat(ring.rawValue) * band - band * 0.4
                let bins = coverage.bins(ring)
                let gap = min(2.0, 120.0 / Double(bins) * 0.2)
                for bin in 0..<bins {
                    let a0 = Double(bin) / Double(bins) * 360 + gap
                    let a1 = Double(bin + 1) / Double(bins) * 360 - gap
                    let path = Self.arc(center: center, radius: radius, from: a0, to: a1)
                    let isCurrent = current.map { $0.ring == ring && $0.bin == bin } ?? false
                    var color: Color
                    if isCurrent { color = .white }
                    else if coverage.isCovered(ring, bin: bin) { color = .green }
                    else if isActive && bin == targetBin { color = .yellow }
                    else { color = .gray.opacity(0.5) }
                    if !isActive && !isCurrent { color = color.opacity(skipped.contains(ring) ? 0.15 : 0.55) }
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }
        }
        .accessibilityLabel("覆盖进度")
    }

    /// Polyline arc; 0° is up, angles increase clockwise on screen.
    static func arc(center: CGPoint, radius: CGFloat, from a0: Double, to a1: Double) -> Path {
        var p = Path()
        let steps = 6
        for i in 0...steps {
            let deg = a0 + (a1 - a0) * Double(i) / Double(steps)
            let rad = deg * .pi / 180
            let pt = CGPoint(x: center.x + radius * CGFloat(sin(rad)), y: center.y - radius * CGFloat(cos(rad)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Three little progress rows: 中位 12/22 ✓ …
struct RingProgressList: View {
    let progress: [RingProgress]
    let active: ElevationRing?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(progress.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 6) {
                    Image(systemName: p.skipped ? "forward.circle" : p.isComplete ? "checkmark.circle.fill" : (p.ring == active ? "circle.dotted" : "circle"))
                        .foregroundStyle(p.isComplete && !p.skipped ? .green : .white)
                    Text("\(i + 1). \(CaptureStrings.ringName(p.ring))")
                        .fontWeight(p.ring == active ? .bold : .regular)
                    Spacer(minLength: 4)
                    Text(p.skipped ? "跳过" : "\(min(p.covered, p.required))/\(p.required)")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .frame(width: 118)
    }
}
