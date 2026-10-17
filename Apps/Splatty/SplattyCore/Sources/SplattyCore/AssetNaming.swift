import Foundation

public enum AssetNaming {
    /// Lowercase alphabet without look-alikes (no 0/o, 1/l/i).
    public static let shortIDAlphabet = Array("23456789abcdefghjkmnpqrstuvwxyz")

    /// Random short id (default 6 chars).
    public static func shortID<G: RandomNumberGenerator>(length: Int = 6, using rng: inout G) -> String {
        String((0..<length).map { _ in shortIDAlphabet.randomElement(using: &rng)! })
    }

    public static func shortID(length: Int = 6) -> String {
        var g = SystemRandomNumberGenerator()
        return shortID(length: length, using: &g)
    }

    /// URL/path-safe ASCII slug. Non-Latin names are transliterated where the
    /// platform supports it (Apple: 皮卡丘 → "pi-ka-qiu"); falls back to `fallback`.
    public static func slug(_ name: String, fallback: String = "object", maxLength: Int = 32) -> String {
        var s = name
        #if canImport(Darwin)
        s = s.applyingTransform(.toLatin, reverse: false) ?? s
        s = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        #endif
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        s = s.lowercased()
        var out = ""
        var lastDash = false
        for scalar in s.unicodeScalars {
            let isAlnum = scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)))
            if isAlnum {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            out = String(out.prefix(maxLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? fallback : out
    }

    /// `YYYYMMDD` in the given time zone.
    public static func dateStamp(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYYMMDD_<slug>_<shortid>`.
    public static func folderName(date: Date, timeZone: TimeZone, name: String, category: AssetCategory, shortID: String) -> String {
        "\(dateStamp(date, timeZone: timeZone))_\(slug(name, fallback: category.rawValue))_\(shortID)"
    }

    /// ISO 8601 with numeric offset in `timeZone` (never "Z" unless UTC).
    public static func iso8601(_ date: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `frame_00001` (1-based).
    public static func frameStem(_ index: Int) -> String { String(format: "frame_%05d", index) }
}
