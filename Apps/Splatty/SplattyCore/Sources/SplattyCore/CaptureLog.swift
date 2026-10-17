import Foundation

/// `capture_log.json`: what happened during a capture (shots, rejected-shot reasons,
/// write errors, exposure-lock state), so a bad export can be diagnosed on the Mac.
public struct CaptureLog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Seconds since the capture screen opened.
        public var t: Double
        /// shot / rejected / error / info / exposure
        public var kind: String
        public var message: String
        public var count: Int

        public init(t: Double, kind: String, message: String, count: Int = 1) {
            self.t = t
            self.kind = kind
            self.message = message
            self.count = count
        }
    }

    public var captureMode: String
    public var startedAt: String
    public var entries: [Entry] = []
    /// Totals per rejection reason (whole session, never truncated).
    public var rejectionTotals: [String: Int] = [:]
    public var maxEntries = 3000

    public init(captureMode: String, startedAt: String) {
        self.captureMode = captureMode
        self.startedAt = startedAt
    }

    /// Adds an entry; repeated identical consecutive entries are folded into `count`.
    public mutating func add(_ kind: String, _ message: String, t: Double) {
        let t = t.isFinite ? t : 0
        if kind == "rejected" { rejectionTotals[message, default: 0] += 1 }
        if var last = entries.last, last.kind == kind, last.message == message {
            last.count += 1
            entries[entries.count - 1] = last
            return
        }
        entries.append(Entry(t: t, kind: kind, message: message))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try enc.encode(self)
    }
}
