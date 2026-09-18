import Foundation

// MARK: - 집계 단위

/// 토큰 5종 + 비용 누적기.
struct Totals {
    var input: Int64 = 0
    var cacheWrite5m: Int64 = 0
    var cacheWrite1h: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var cost: Double = 0
    var requests: Int = 0

    var total: Int64 { input + cacheWrite5m + cacheWrite1h + cacheRead + output }

    mutating func add(_ r: Rec, cost c: Double) {
        input += Int64(r.input)
        cacheWrite5m += Int64(r.cw5)
        cacheWrite1h += Int64(r.cw1)
        cacheRead += Int64(r.cr)
        output += Int64(r.out)
        cost += c
        requests += 1
    }
}

/// 중복 제거를 마친 단일 API 요청 1건.
struct Rec {
    var ts: Int32       // UTC epoch seconds
    var day: Int32      // 로컬 기준 일자 번호 (epochDay)
    var model: Int32    // Snapshot.models 인덱스
    var project: Int32  // Snapshot.projects 인덱스
    var session: Int32  // Snapshot.sessions 인덱스
    var input: Int32
    var cw5: Int32
    var cw1: Int32
    var cr: Int32
    var out: Int32

    var total: Int64 {
        Int64(input) + Int64(cw5) + Int64(cw1) + Int64(cr) + Int64(out)
    }
}

// MARK: - 가격표

/// 100만 토큰당 USD. 캐시 요율은 입력가 대비 배수 (쓰기 5분 1.25x / 1시간 2x, 읽기 0.1x).
struct Price {
    let input: Double
    let output: Double
    var cw5m: Double { input * 1.25 }
    var cw1h: Double { input * 2.0 }
    var cacheRead: Double { input * 0.1 }

    static func isFableName(_ s: String) -> Bool {
        s.hasPrefix("claude-fable") || s.hasPrefix("claude-mythos")
    }

    /// Sonnet 5 는 2026-08-31 까지 도입가($2/$10)가 적용된다. 2026년 데이터는 전부 그 구간.
    static func of(_ model: String) -> Price? {
        if model.hasPrefix("claude-fable-5") || model.hasPrefix("claude-mythos-5") {
            return Price(input: 10, output: 50)
        }
        if model.hasPrefix("claude-opus-") { return Price(input: 5, output: 25) }
        if model.hasPrefix("claude-sonnet-5") { return Price(input: 2, output: 10) }  // 도입가
        if model.hasPrefix("claude-sonnet-") { return Price(input: 3, output: 15) }
        if model.hasPrefix("claude-haiku-4") { return Price(input: 1, output: 5) }
        if model.hasPrefix("claude-haiku-3-5") { return Price(input: 0.8, output: 4) }
        if model.hasPrefix("claude-3-haiku") { return Price(input: 0.25, output: 1.25) }
        return nil  // <synthetic>, 서드파티 모델 등 → 비용 0 처리
    }

    func cost(_ r: Rec) -> Double {
        let m = 1.0 / 1_000_000.0
        return (Double(r.input) * input
            + Double(r.cw5) * cw5m
            + Double(r.cw1) * cw1h
            + Double(r.cr) * cacheRead
            + Double(r.out) * output) * m
    }
}

// MARK: - 5시간 블록

struct Block {
    var start: Int32
    var end: Int32
    var totals = Totals()
    var byModel: [Int32: Int64] = [:]

    var isActive: Bool { Int32(Date().timeIntervalSince1970) < end }
}

// MARK: - 스캔 결과 전체

struct NamedTotals: Identifiable {
    let id: Int32
    let name: String
    let totals: Totals
    var subtitle: String = ""
}

final class Snapshot {
    var records: [Rec] = []          // ts 오름차순
    var models: [String] = []
    var projects: [String] = []
    var sessions: [String] = []
    var scannedFiles = 0
    var rawLines = 0
    var duplicatesDropped = 0
    var scanSeconds: Double = 0
    var generatedAt = Date()

    // 집계 캐시
    private(set) var byModel: [Int32: Totals] = [:]
    private(set) var byProject: [Int32: Totals] = [:]
    private(set) var bySession: [Int32: Totals] = [:]
    private(set) var byDay: [Int32: Totals] = [:]
    private(set) var byDayModel: [Int64: Totals] = [:]   // key = day<<20 | model
    private(set) var sessionProject: [Int32: Int32] = [:]
    private(set) var sessionSpan: [Int32: (Int32, Int32)] = [:]
    private(set) var sessionTopModel: [Int32: Int32] = [:]
    private(set) var blocks: [Block] = []
    private(set) var grand = Totals()

    // 주간 한도(7일 롤링) 관련
    private(set) var modelPrices: [Price?] = []
    private(set) var fableModels: Set<Int32> = []
    private(set) var maxWeekAll: Int64 = 0     // 역대 최대 7일 롤링 합 (전체)
    private(set) var maxWeekFable: Int64 = 0   // 역대 최대 7일 롤링 합 (Fable 계열만)

    static let weekWindow: Int32 = 7 * 24 * 3600

    var isEmpty: Bool { records.isEmpty }

    /// 레코드 1회 순회로 모든 축의 합계와 비용을 동시에 계산한다.
    func aggregate() {
        let prices = models.map { Price.of($0) }
        var sessModelTokens: [Int64: Int64] = [:]

        for r in records {
            let c = prices[Int(r.model)]?.cost(r) ?? 0
            grand.add(r, cost: c)
            byModel[r.model, default: Totals()].add(r, cost: c)
            byProject[r.project, default: Totals()].add(r, cost: c)
            bySession[r.session, default: Totals()].add(r, cost: c)
            byDay[r.day, default: Totals()].add(r, cost: c)
            byDayModel[Int64(r.day) << 20 | Int64(r.model), default: Totals()].add(r, cost: c)

            sessionProject[r.session] = r.project
            if let span = sessionSpan[r.session] {
                sessionSpan[r.session] = (min(span.0, r.ts), max(span.1, r.ts))
            } else {
                sessionSpan[r.session] = (r.ts, r.ts)
            }
            sessModelTokens[Int64(r.session) << 20 | Int64(r.model), default: 0] += r.total
        }

        for (k, v) in sessModelTokens {
            let s = Int32(k >> 20), m = Int32(k & 0xFFFFF)
            let cur = sessionTopModel[s]
            if cur == nil || v > (sessModelTokens[Int64(s) << 20 | Int64(cur!)] ?? 0) {
                sessionTopModel[s] = m
            }
        }

        modelPrices = prices
        for (i, name) in models.enumerated() where Price.isFableName(name) {
            fableModels.insert(Int32(i))
        }
        maxWeekAll = maxRolling(Snapshot.weekWindow, fableOnly: false)
        maxWeekFable = maxRolling(Snapshot.weekWindow, fableOnly: true)

        buildBlocks(prices: prices)
    }

    /// records 는 ts 오름차순. 임의의 `window` 초 구간에서 나온 최대 토큰 합을 two-pointer 로 구한다.
    /// 주간 한도 게이지의 기준값(역대 최대 7일 사용량)으로 쓴다.
    private func maxRolling(_ window: Int32, fableOnly: Bool) -> Int64 {
        var pts: [(ts: Int32, tok: Int64)] = []
        pts.reserveCapacity(records.count)
        for r in records {
            if fableOnly && !fableModels.contains(r.model) { continue }
            pts.append((r.ts, r.total))
        }
        var left = 0, sum: Int64 = 0, best: Int64 = 0
        for right in pts.indices {
            sum += pts[right].tok
            while pts[right].ts - pts[left].ts >= window { sum -= pts[left].tok; left += 1 }
            if sum > best { best = sum }
        }
        return best
    }

    @inline(__always) func isFable(_ modelIndex: Int32) -> Bool { fableModels.contains(modelIndex) }

    /// Claude 의 5시간 사용량 블록. 첫 요청 시각을 정시로 내림한 지점에서 시작하고,
    /// 5시간이 지나거나 5시간 이상 공백이 생기면 새 블록을 연다.
    private func buildBlocks(prices: [Price?]) {
        let fiveHours: Int32 = 5 * 3600
        var out: [Block] = []
        var lastTs: Int32 = 0
        for r in records {
            let needsNew = out.isEmpty
                || r.ts >= out[out.count - 1].start + fiveHours
                || r.ts >= lastTs + fiveHours
            if needsNew {
                let start = TimeUtil.floorToLocalHour(r.ts)
                out.append(Block(start: start, end: start + fiveHours))
            }
            let c = prices[Int(r.model)]?.cost(r) ?? 0
            out[out.count - 1].totals.add(r, cost: c)
            out[out.count - 1].byModel[r.model, default: 0] += r.total
            lastTs = r.ts
        }
        blocks = out
    }

    // MARK: 파생 조회

    var activeBlock: Block? { blocks.last.flatMap { $0.isActive ? $0 : nil } }
    var maxBlockTokens: Int64 { blocks.map(\.totals.total).max() ?? 0 }

    /// [from, to] 구간 사용량. records 는 ts 오름차순.
    func usageRange(from: Int32, to: Int32, fableOnly: Bool = false) -> Totals {
        var t = Totals()
        for r in records {
            if r.ts < from { continue }
            if r.ts > to { break }
            if fableOnly && !fableModels.contains(r.model) { continue }
            t.add(r, cost: modelPrices[Int(r.model)]?.cost(r) ?? 0)
        }
        return t
    }

    func blockContaining(_ ts: Int32) -> Block? {
        blocks.first { ts >= $0.start && ts < $0.end }
    }

    /// 설정의 리셋 기준으로 `now` 를 포함하는 이번 주 창.
    func weeklyWindow(_ c: Config, now: Int32 = Int32(Date().timeIntervalSince1970)) -> (start: Int32, end: Int32) {
        TimeUtil.weeklyWindow(weekday: c.weeklyResetWeekday, hour: c.weeklyResetHour, now: now)
    }

    /// 설정(수동 한도 또는 보정 %)으로부터 실제 한도를 역산한다.
    func derivedLimits(_ c: Config) -> DerivedLimits {
        var out = DerivedLimits()
        out.fiveHour = c.limitFiveHour ?? 0
        out.weeklyAll = c.limitWeeklyAll ?? 0
        out.weeklyFable = c.limitWeeklyFable ?? 0

        if let cal = c.calibration {
            let (ws, _) = weeklyWindow(c, now: cal.at)
            if out.weeklyAll == 0, let p = cal.weeklyPercent, p > 0 {
                out.weeklyAll = Int64((Double(usageRange(from: ws, to: cal.at).total) / p).rounded())
                out.calibrated = true
            }
            if out.weeklyFable == 0, let p = cal.fablePercent, p > 0 {
                out.weeklyFable = Int64((Double(usageRange(from: ws, to: cal.at, fableOnly: true).total) / p).rounded())
                out.calibrated = true
            }
            if out.fiveHour == 0, let p = cal.fiveHourPercent, p > 0, let b = blockContaining(cal.at) {
                out.fiveHour = Int64((Double(usageRange(from: b.start, to: cal.at).total) / p).rounded())
                out.calibrated = true
            }
        }
        return out
    }

    /// 최근 `minutes` 분 소모 속도 (토큰/분). outputOnly=true 면 출력 토큰만(한도 단위).
    func burnRate(minutes: Int, outputOnly: Bool = false) -> Double {
        let cutoff = Int32(Date().timeIntervalSince1970) - Int32(minutes * 60)
        var sum: Int64 = 0
        for r in records.reversed() {
            if r.ts < cutoff { break }
            sum += outputOnly ? Int64(r.out) : r.total
        }
        return Double(sum) / Double(minutes)
    }

    func totals(fromDay lo: Int32, toDay hi: Int32) -> Totals {
        var t = Totals()
        for (d, v) in byDay where d >= lo && d <= hi {
            t.input += v.input; t.cacheWrite5m += v.cacheWrite5m; t.cacheWrite1h += v.cacheWrite1h
            t.cacheRead += v.cacheRead; t.output += v.output; t.cost += v.cost; t.requests += v.requests
        }
        return t
    }

    /// 토큰이 0인 항목(<synthetic> 등 로그 아티팩트)은 표시에서 제외한다.
    func rankedModels() -> [NamedTotals] {
        byModel.filter { $0.value.total > 0 }
            .map { NamedTotals(id: $0.key, name: models[Int($0.key)], totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
    }

    func rankedProjects() -> [NamedTotals] {
        byProject.map {
            NamedTotals(id: $0.key, name: ProjectName.pretty(projects[Int($0.key)]), totals: $0.value,
                        subtitle: projects[Int($0.key)])
        }.sorted { $0.totals.total > $1.totals.total }
    }

    func rankedSessions(limit: Int = 200) -> [NamedTotals] {
        bySession.map { key, tot -> NamedTotals in
            let proj = sessionProject[key].map { ProjectName.pretty(projects[Int($0)]) } ?? "-"
            let span = sessionSpan[key] ?? (0, 0)
            let model = sessionTopModel[key].map { models[Int($0)] } ?? "-"
            let range = TimeUtil.dayString(TimeUtil.localDay(span.0))
                + (TimeUtil.localDay(span.0) == TimeUtil.localDay(span.1)
                   ? "" : " → " + TimeUtil.dayString(TimeUtil.localDay(span.1)))
            return NamedTotals(id: key, name: proj, totals: tot,
                               subtitle: "\(range) · \(model) · \(String(sessions[Int(key)].prefix(8)))")
        }
        .sorted { $0.totals.total > $1.totals.total }
        .prefix(limit)
        .map { $0 }
    }

    /// 일자 오름차순 (일자, 합계) 목록.
    func dailySeries() -> [(day: Int32, totals: Totals)] {
        byDay.map { (day: $0.key, totals: $0.value) }.sorted { $0.day < $1.day }
    }

    /// 스택 막대용 (일자, 모델명, 토큰) 목록.
    func dailyByModelSeries(lastDays: Int) -> [(day: Int32, model: String, tokens: Int64)] {
        let days = byDay.keys.sorted()
        guard let cut = days.suffix(lastDays).first else { return [] }
        return byDayModel.compactMap { key, v in
            let d = Int32(key >> 20)
            guard d >= cut, v.total > 0 else { return nil }
            return (day: d, model: models[Int(key & 0xFFFFF)], tokens: v.total)
        }.sorted { $0.day < $1.day }
    }
}

enum ProjectName {
    /// "-Users-wk-ai-EVS" → "ai/EVS"
    static func pretty(_ dir: String) -> String {
        var s = dir
        if s.hasPrefix("-Users-wk-") { s = String(s.dropFirst("-Users-wk-".count)) }
        else if s.hasPrefix("-Users-") { s = String(s.dropFirst("-Users-".count)) }
        s = s.replacingOccurrences(of: "-", with: "/")
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return s.isEmpty ? dir : s
    }
}
