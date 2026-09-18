import Foundation

// MARK: - Codex 집계 타입
//
// Claude 와 필드 의미가 다르다. 반드시 아래 관계를 지킬 것:
//   total = input + output   (cached 는 input 의 **부분집합**, reasoning 은 output 의 부분집합)
// Claude 처럼 cacheRead 를 따로 더하면 캐시가 이중 계상된다.

struct CodexTotals {
    var input: Int64 = 0        // 총 입력 (캐시 읽기 포함)
    var cached: Int64 = 0       // 그중 캐시 읽기
    var cacheWrite: Int64 = 0
    var output: Int64 = 0       // 총 출력 (추론 포함)
    var reasoning: Int64 = 0    // 그중 추론
    var events: Int = 0

    var total: Int64 { input + output }
    var freshInput: Int64 { max(0, input - cached) }

    mutating func add(_ r: CodexRec) {
        input += Int64(r.input); cached += Int64(r.cached); cacheWrite += Int64(r.cacheWrite)
        output += Int64(r.output); reasoning += Int64(r.reasoning); events += 1
    }
}

/// token_count 이벤트 1건의 **증가분**(델타).
struct CodexRec {
    var ts: Int32
    var day: Int32
    var model: Int32
    var project: Int32
    var plan: Int32          // 계정 대용 (rate_limits.plan_type)
    var input: Int32
    var cached: Int32
    var cacheWrite: Int32
    var output: Int32
    var reasoning: Int32

    var total: Int64 { Int64(input) + Int64(output) }
}

/// 로그에 박혀 있는 공식 사용률 (API 호출 불필요).
struct CodexRateWindow {
    var usedPercent: Double
    var windowMinutes: Int
    var resetsAt: Int32?
}

struct CodexRateLimits {
    var fiveHour: CodexRateWindow?
    var weekly: CodexRateWindow?
    var planType: String = ""
    var observedAt: Int32 = 0

    var age: String {
        guard observedAt > 0 else { return "-" }
        let s = Int(Date().timeIntervalSince1970) - Int(observedAt)
        if s < 3600 { return "\(max(0, s / 60))분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }
}

/// 현재 로그인된 Codex 계정 (`~/.codex/auth.json` 의 id_token 클레임).
/// 세션 로그에는 계정 식별자가 **없어서**, 과거 기록을 계정별로 나눌 유일한 단서가
/// `rate_limits.plan_type` 이다. 그래서 "지금 계정의 플랜"을 알아야 한다.
struct CodexAccount {
    var email = ""
    var planType = ""
    var accountId = ""
    var loaded = false

    var label: String {
        if !loaded { return "계정 정보 없음" }
        let p = planType.isEmpty ? "-" : planType
        return email.isEmpty ? "plan: \(p)" : "\(email) · \(p)"
    }

    static func current() -> CodexAccount {
        var out = CodexAccount()
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any] else { return out }
        out.accountId = (tokens["account_id"] as? String) ?? ""
        guard let jwt = tokens["id_token"] as? String else { out.loaded = !out.accountId.isEmpty; return out }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { out.loaded = true; return out }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                  .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let pd = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] else {
            out.loaded = true; return out
        }
        out.email = (claims["email"] as? String) ?? ""
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            out.planType = (auth["chatgpt_plan_type"] as? String) ?? ""
            if out.accountId.isEmpty { out.accountId = (auth["chatgpt_account_id"] as? String) ?? "" }
        }
        out.loaded = true
        return out
    }
}

final class CodexSnapshot {
    var records: [CodexRec] = []        // ts 오름차순
    var models: [String] = []
    var projects: [String] = []
    var rateLimits = CodexRateLimits()          // 현재 계정 플랜의 것 (없으면 최신)
    var rateLimitsByPlan: [String: CodexRateLimits] = [:]
    var account = CodexAccount()
    var scannedFiles = 0
    var resetSegments = 0
    var scanSeconds: Double = 0

    var plans: [String] = []
    /// plan 인덱스별 집계. key -1 = 전체.
    private(set) var slices: [Int32: CodexSlice] = [:]

    var isEmpty: Bool { records.isEmpty }
    var all: CodexSlice { slices[-1] ?? CodexSlice() }

    /// 화면에 보여줄 계정(플랜) 목록 — 사용량 많은 순.
    func planOptions() -> [(index: Int32, name: String, totals: CodexTotals)] {
        slices.filter { $0.key >= 0 && $0.value.grand.total > 0 }
            .map { (index: $0.key, name: plans[Int($0.key)], totals: $0.value.grand) }
            .sorted { $0.totals.total > $1.totals.total }
    }

    func slice(_ plan: Int32?) -> CodexSlice { slices[plan ?? -1] ?? CodexSlice() }

    func aggregate() {
        var out: [Int32: CodexSlice] = [-1: CodexSlice()]
        for r in records {
            out[-1]!.add(r)
            out[r.plan, default: CodexSlice()].add(r)
        }
        slices = out
    }

}

/// 한 계정(플랜) 또는 전체의 집계 묶음.
struct CodexSlice {
    var byDay: [Int32: CodexTotals] = [:]
    var byModel: [Int32: CodexTotals] = [:]
    var byProject: [Int32: CodexTotals] = [:]
    var grand = CodexTotals()

    mutating func add(_ r: CodexRec) {
        grand.add(r)
        byDay[r.day, default: CodexTotals()].add(r)
        byModel[r.model, default: CodexTotals()].add(r)
        byProject[r.project, default: CodexTotals()].add(r)
    }

    func totals(fromDay lo: Int32, toDay hi: Int32) -> CodexTotals {
        var t = CodexTotals()
        for (d, v) in byDay where d >= lo && d <= hi {
            t.input += v.input; t.cached += v.cached; t.cacheWrite += v.cacheWrite
            t.output += v.output; t.reasoning += v.reasoning; t.events += v.events
        }
        return t
    }

    func rankedModels(_ names: [String]) -> [(name: String, totals: CodexTotals)] {
        byModel.filter { $0.value.total > 0 }
            .map { (names[Int($0.key)], $0.value) }
            .sorted { $0.1.total > $1.1.total }
    }

    func rankedProjects(_ paths: [String]) -> [(name: String, path: String, totals: CodexTotals)] {
        byProject.filter { $0.value.total > 0 }
            .map { (URL(fileURLWithPath: paths[Int($0.key)]).lastPathComponent,
                    paths[Int($0.key)], $0.value) }
            .sorted { $0.2.total > $1.2.total }
    }

    func dailySeries() -> [(day: Int32, totals: CodexTotals)] {
        byDay.map { (day: $0.key, totals: $0.value) }.sorted { $0.day < $1.day }
    }
}

// MARK: - 스캐너

/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 파싱.
///
/// Claude 로그와 다른 4가지 함정 (전부 실측 확인):
///  1. `total_token_usage` 는 **세션 누계** → 그냥 더하면 폭증. 증가분만 합산한다
///     (중복 이벤트는 diff 0 이 되어 자동 배제된다).
///  2. 필드가 포함관계다 — `total = input + output`, `cached ⊂ input`.
///  3. 파일명 날짜 ≠ 내용 날짜 (resume 로 5월 파일에 8월 이벤트) → 줄 타임스탬프로 귀속.
///  4. 파일 1개에 세션이 여럿(최대 4) → cwd/model 은 줄을 읽어가며 갱신한다.
enum CodexScanner {

    struct Progress { var done: Int; var total: Int }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: defaultRoot().path)
    }

    static func scan(root: URL = defaultRoot(),
                     year: Int? = 2026,
                     progress: ((Progress) -> Void)? = nil) -> CodexSnapshot {
        let t0 = Date()
        let snap = CodexSnapshot()
        let files = listJSONL(root)
        snap.scannedFiles = files.count
        guard !files.isEmpty else { snap.scanSeconds = Date().timeIntervalSince(t0); return snap }

        let lock = NSLock()
        var parsed = [FileResult]()
        parsed.reserveCapacity(files.count)
        var done = 0

        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let r = parseFile(files[i])
            lock.lock()
            parsed.append(r)
            done += 1
            if done % 32 == 0 { progress?(Progress(done: done, total: files.count)) }
            lock.unlock()
        }
        progress?(Progress(done: files.count, total: files.count))

        var modelIdx = [String: Int32](), projIdx = [String: Int32](), planIdx = [String: Int32]()
        var records = [CodexRec]()
        records.reserveCapacity(60_000)

        let dayLo: Int32?, dayHi: Int32?
        if let y = year {
            dayLo = Int32(TimeUtil.daysFromCivil(y, 1, 1))
            dayHi = Int32(TimeUtil.daysFromCivil(y + 1, 1, 1)) - 1
        } else { dayLo = nil; dayHi = nil }

        for f in parsed {
            snap.resetSegments += f.resets
            for row in f.rows {
                guard row.ts > 0 else { continue }
                let day = TimeUtil.localDay(row.ts)
                if let lo = dayLo, let hi = dayHi, day < lo || day > hi { continue }
                records.append(CodexRec(
                    ts: row.ts, day: day,
                    model: intern(row.model, &modelIdx, &snap.models),
                    project: intern(row.project, &projIdx, &snap.projects),
                    plan: intern(row.plan.isEmpty ? "미상" : row.plan, &planIdx, &snap.plans),
                    input: row.input, cached: row.cached, cacheWrite: row.cacheWrite,
                    output: row.output, reasoning: row.reasoning))
            }
            // 플랜(=계정 프록시)별로 최신 관측을 보관한다
            for (plan, rl) in f.rateLimits {
                if let cur = snap.rateLimitsByPlan[plan], cur.observedAt >= rl.observedAt { continue }
                snap.rateLimitsByPlan[plan] = rl
            }
        }

        // 한도 게이지는 **지금 로그인된 계정의 플랜** 것을 쓴다.
        // (여러 계정을 오가면 전역 최신값은 남의 계정 한도일 수 있다)
        snap.account = CodexAccount.current()
        if !snap.account.planType.isEmpty, let mine = snap.rateLimitsByPlan[snap.account.planType] {
            snap.rateLimits = mine
        } else if let newest = snap.rateLimitsByPlan.values.max(by: { $0.observedAt < $1.observedAt }) {
            snap.rateLimits = newest
        }

        records.sort { $0.ts < $1.ts }
        snap.records = records
        snap.scanSeconds = Date().timeIntervalSince(t0)
        snap.aggregate()
        return snap
    }

    @inline(__always)
    private static func intern(_ s: String, _ map: inout [String: Int32], _ list: inout [String]) -> Int32 {
        if let i = map[s] { return i }
        let i = Int32(list.count)
        list.append(s); map[s] = i
        return i
    }

    private static func listJSONL(_ root: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" { out.append(url) }
        return out
    }

    // MARK: 파일 1개

    private struct Row {
        var ts: Int32
        var model: String
        var project: String
        var plan: String
        var input: Int32, cached: Int32, cacheWrite: Int32, output: Int32, reasoning: Int32
    }

    private struct FileResult {
        var rows: [Row] = []
        var resets = 0
        var rateLimits: [String: CodexRateLimits] = [:]   // plan_type → 최신 관측
    }

    private static let kTokenCount = Array(#""token_count""#.utf8)
    private static let kTurnContext = Array(#""turn_context""#.utf8)
    private static let kSessionMeta = Array(#""session_meta""#.utf8)

    private static func parseFile(_ url: URL) -> FileResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return FileResult() }
        var res = FileResult()
        var model = "unknown"
        var project = "unknown"
        // 파일(프로세스) 단위 누적 카운터의 직전 값
        var prev = (i: 0, c: 0, cw: 0, o: 0, r: 0)
        // rate_limits 는 매 이벤트에 있지는 않다. 파일(=대개 한 계정) 안에서 마지막으로
        // 관측된 plan 을 이어 쓰고, 첫 관측 이전 구간은 끝에서 소급 채운다.
        var curPlan = ""

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var lo = 0
            let n = buf.count
            var i = 0
            while i <= n {
                if i == n || buf[i] == 0x0A {
                    if i > lo {
                        let hasTC = contains(buf, kTokenCount, lo, i)
                        let hasCtx = !hasTC && contains(buf, kTurnContext, lo, i)
                        let hasMeta = !hasTC && !hasCtx && contains(buf, kSessionMeta, lo, i)
                        if hasTC || hasCtx || hasMeta {
                            let slice = Data(buf[lo..<i])
                            if let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                                let payload = (obj["payload"] as? [String: Any]) ?? obj
                                let type = (payload["type"] as? String) ?? (obj["type"] as? String) ?? ""
                                switch type {
                                case "session_meta":
                                    if let c = payload["cwd"] as? String, !c.isEmpty { project = c }
                                case "turn_context":
                                    if let m = payload["model"] as? String, !m.isEmpty { model = m }
                                case "token_count":
                                    handleTokenCount(payload, obj, model: model, project: project,
                                                     plan: &curPlan, prev: &prev, res: &res)
                                default: break
                                }
                            }
                        }
                    }
                    lo = i + 1
                }
                i += 1
            }
        }
        // 첫 plan 관측 이전 행들을 소급 적용
        if let firstKnown = res.rows.first(where: { !$0.plan.isEmpty })?.plan {
            for i in res.rows.indices where res.rows[i].plan.isEmpty { res.rows[i].plan = firstKnown }
        }
        return res
    }

    private static func handleTokenCount(_ payload: [String: Any], _ obj: [String: Any],
                                         model: String, project: String,
                                         plan: inout String,
                                         prev: inout (i: Int, c: Int, cw: Int, o: Int, r: Int),
                                         res: inout FileResult) {
        if let rl = payload["rate_limits"] as? [String: Any],
           let ts = (obj["timestamp"] as? String).flatMap(parseTS), ts > 0 {
            var out = CodexRateLimits(planType: (rl["plan_type"] as? String) ?? "", observedAt: ts)
            if !out.planType.isEmpty { plan = out.planType }
            for slot in ["primary", "secondary"] {
                guard let w = rl[slot] as? [String: Any],
                      let pct = num(w["used_percent"]) else { continue }
                let mins = Int(num(w["window_minutes"]) ?? 0)
                let win = CodexRateWindow(usedPercent: pct, windowMinutes: mins,
                                          resetsAt: num(w["resets_at"]).map { Int32($0) })
                // 위치가 아니라 창 길이로 분류한다 (파일마다 primary/secondary 가 뒤바뀐다)
                if mins <= 600 { out.fiveHour = win } else { out.weekly = win }
            }
            if out.fiveHour != nil || out.weekly != nil {
                let key = out.planType.isEmpty ? "unknown" : out.planType
                if let cur = res.rateLimits[key], cur.observedAt >= ts {} else { res.rateLimits[key] = out }
            }
        }

        guard let info = payload["info"] as? [String: Any],
              let cur = info["total_token_usage"] as? [String: Any] else { return }
        let ci = Int(num(cur["input_tokens"]) ?? 0)
        let cc = Int(num(cur["cached_input_tokens"]) ?? 0)
        let cw = Int(num(cur["cache_write_input_tokens"]) ?? 0)
        let co = Int(num(cur["output_tokens"]) ?? 0)
        let cr = Int(num(cur["reasoning_output_tokens"]) ?? 0)

        // 누계가 줄면 새 구간(리셋) → 현재값 자체가 증가분
        let isReset = (ci + co) < (prev.i + prev.o)
        let d = isReset
            ? (ci, cc, cw, co, cr)
            : (max(0, ci - prev.i), max(0, cc - prev.c), max(0, cw - prev.cw),
               max(0, co - prev.o), max(0, cr - prev.r))
        if isReset { res.resets += 1 }
        prev = (ci, cc, cw, co, cr)
        guard d.0 + d.3 > 0 else { return }   // 중복 이벤트(증가분 0)는 버림

        guard let ts = (obj["timestamp"] as? String).flatMap(parseTS), ts > 0 else { return }
        res.rows.append(Row(ts: ts, model: model, project: project, plan: plan,
                            input: Int32(clamping: d.0), cached: Int32(clamping: d.1),
                            cacheWrite: Int32(clamping: d.2), output: Int32(clamping: d.3),
                            reasoning: Int32(clamping: d.4)))
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// "2026-08-11T03:28:20.733Z" → epoch. TimeUtil 의 고정 포맷 파서 재사용.
    private static func parseTS(_ s: String) -> Int32? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 19 else { return nil }
        return bytes.withUnsafeBytes { TimeUtil.parseISO($0, 0) }
    }

    @inline(__always)
    private static func contains(_ b: UnsafeRawBufferPointer, _ needle: [UInt8], _ lo: Int, _ hi: Int) -> Bool {
        let n = needle.count
        let last = hi - n
        if last < lo { return false }
        let first = needle[0]
        var i = lo
        while i <= last {
            if b[i] == first {
                var j = 1
                while j < n && b[i + j] == needle[j] { j += 1 }
                if j == n { return true }
            }
            i += 1
        }
        return false
    }
}
