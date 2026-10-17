import SplattyCore
import SwiftUI

/// Three concentric rings (outer = low, inner = high), one arc per azimuth bin.
/// Green = has a shot, grey = missing, white = where the camera is now.
struct CoverageRingsView: View {
    let coverage: CoverageMap
    let current: (ring: ElevationRing, bin: Int)?

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2 - 6
            let lineWidth = maxR * 0.2
            let bins = coverage.binsPerRing
            for ring in ElevationRing.allCases {
                // low → outer
                let radius = maxR - CGFloat(ring.rawValue) * (lineWidth + 4) - lineWidth / 2
                for bin in 0..<bins {
                    let a0 = Double(bin) / Double(bins) * 360 + 1.5
                    let a1 = Double(bin + 1) / Double(bins) * 360 - 1.5
                    let path = Self.arc(center: center, radius: radius, from: a0, to: a1)
                    let isCurrent = current.map { $0.ring == ring && $0.bin == bin } ?? false
                    let color: Color = isCurrent ? .white
                        : coverage.isCovered(ring, bin: bin) ? .green : .gray.opacity(0.45)
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }
        }
        .accessibilityLabel("Coverage: low \(pct(.low)), mid \(pct(.mid)), high \(pct(.high))")
    }

    private func pct(_ r: ElevationRing) -> String { "\(Int((coverage.fraction(r) * 100).rounded()))%" }

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

struct CoverageLegend: View {
    let coverage: CoverageMap

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(ElevationRing.allCases.reversed()), id: \.self) { ring in
                HStack(spacing: 4) {
                    Text(ring.label).frame(width: 34, alignment: .leading)
                    ProgressView(value: coverage.fraction(ring)).frame(width: 60)
                    Text("\(Int((coverage.fraction(ring) * 100).rounded()))%").monospacedDigit()
                }
            }
        }
        .font(.caption2)
    }
}
