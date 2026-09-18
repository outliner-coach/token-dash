import Foundation

enum Fmt {
    /// 억 / 만 단위 한국식 축약. 참고 이미지와 동일 규칙.
    static func tokens(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1e8 { return trim(d / 1e8) + "억" }
        if d >= 1e4 { return trim(d / 1e4) + "만" }
        return decimal(n)
    }

    static func tokens(_ d: Double) -> String { tokens(Int64(d.rounded())) }

    /// 축 라벨용 (소수점 없이).
    static func axis(_ n: Int64) -> String {
        let d = Double(n)
        if d >= 1e8 { return "\(Int((d / 1e8).rounded()))억" }
        if d >= 1e4 { return "\(Int((d / 1e4).rounded()))만" }
        if n == 0 { return "0" }
        return decimal(n)
    }

    static func usd(_ v: Double) -> String {
        if v >= 1000 { return "$" + decimal(Int64(v.rounded())) }
        if v >= 1 { return String(format: "$%.2f", v) }
        if v <= 0 { return "$0" }
        return String(format: "$%.3f", v)
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    /// 소수 1자리 + 정수부 천단위 구분 ("9,921.2", "3.6").
    private static func trim(_ v: Double) -> String {
        let whole = Int64(v)
        let frac = Int((v - Double(whole)) * 10 + 0.5)
        if frac >= 10 { return decimal(whole + 1) + ".0" }
        return decimal(whole) + ".\(frac)"
    }

    static func decimal(_ n: Int64) -> String {
        let s = String(n < 0 ? -n : n)
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// "claude-opus-4-8" → "Opus 4.8"
    static func modelShort(_ m: String) -> String {
        var s = m
        if s.hasPrefix("claude-") { s = String(s.dropFirst(7)) }
        // 날짜 접미사 제거: haiku-4-5-20251001 → haiku-4-5
        let parts = s.split(separator: "-")
        var kept: [String] = []
        for p in parts {
            if p.count == 8, p.allSatisfy(\.isNumber) { continue }
            kept.append(String(p))
        }
        guard let family = kept.first else { return m }
        let version = kept.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
