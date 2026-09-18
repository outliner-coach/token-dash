import Foundation

/// ~/.claude/projects/**/*.jsonl 를 바이트 단위로 훑어 assistant 응답의 usage 만 뽑아낸다.
///
/// 중요: 하나의 API 응답이 content block 개수만큼 여러 줄로 기록되고 각 줄이 **동일한 usage 를
/// 그대로 복사**해 갖는다. 줄 단위로 더하면 실제 사용량의 2배 이상으로 부풀려지므로
/// (message.id, requestId) 조합으로 반드시 중복을 제거해야 한다.
enum Scanner {

    struct Progress {
        var done: Int
        var total: Int
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    static func scan(roots: [URL] = [defaultRoot()],
                     year: Int? = 2026,
                     progress: ((Progress) -> Void)? = nil) -> Snapshot {
        let t0 = Date()
        var files: [FileRef] = []
        for root in roots { files.append(contentsOf: listJSONL(root)) }
        let snap = Snapshot()
        snap.scannedFiles = files.count

        let lock = NSLock()
        var results = [FileResult]()
        results.reserveCapacity(files.count)
        var completed = 0

        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let r = parseFile(files[i])
            lock.lock()
            results.append(r)
            completed += 1
            if completed % 64 == 0 { progress?(Progress(done: completed, total: files.count)) }
            lock.unlock()
        }
        progress?(Progress(done: files.count, total: files.count))

        // 병합 + 중복 제거 (단일 스레드).
        // 같은 요청의 여러 줄에서 input/cache 값은 완전히 동일하지만 output_tokens 만
        // 마지막 줄에 최종값이 실린다(앞줄은 1, 5 같은 부분값). 그래서 첫 줄만 채택하면
        // 출력 토큰이 ~18% 누락된다 → 키가 같으면 output 은 최대값으로 갱신한다.
        var indexOf = [UInt64: Int]()   // 키 → records 인덱스 (-1 = 필터로 제외된 요청)
        indexOf.reserveCapacity(120_000)
        var modelIdx = [String: Int32](), projIdx = [String: Int32](), sessIdx = [String: Int32]()
        var records = [Rec]()
        records.reserveCapacity(120_000)
        var rawLines = 0, dups = 0

        let dayLo: Int32?, dayHi: Int32?
        if let y = year {
            dayLo = Int32(TimeUtil.daysFromCivil(y, 1, 1))
            dayHi = Int32(TimeUtil.daysFromCivil(y + 1, 1, 1)) - 1
        } else { dayLo = nil; dayHi = nil }

        for f in results {
            rawLines += f.rows.count
            let pi = intern(f.project, &projIdx, &snap.projects)
            let si = intern(f.session, &sessIdx, &snap.sessions)
            for row in f.rows {
                if let at = indexOf[row.key] {
                    dups += 1
                    if at >= 0, row.out > records[at].out { records[at].out = row.out }
                    continue
                }
                guard row.ts > 0 else { indexOf[row.key] = -1; continue }
                let day = TimeUtil.localDay(row.ts)
                if let lo = dayLo, let hi = dayHi, day < lo || day > hi {
                    indexOf[row.key] = -1
                    continue
                }
                let mi = intern(row.model, &modelIdx, &snap.models)
                indexOf[row.key] = records.count
                records.append(Rec(ts: row.ts, day: day, model: mi, project: pi, session: si,
                                   input: row.input, cw5: row.cw5, cw1: row.cw1,
                                   cr: row.cr, out: row.out))
            }
        }

        records.sort { $0.ts < $1.ts }
        snap.records = records
        snap.rawLines = rawLines
        snap.duplicatesDropped = dups
        snap.scanSeconds = Date().timeIntervalSince(t0)
        snap.generatedAt = Date()
        snap.aggregate()
        return snap
    }

    @inline(__always)
    private static func intern(_ s: String, _ map: inout [String: Int32], _ list: inout [String]) -> Int32 {
        if let i = map[s] { return i }
        let i = Int32(list.count)
        list.append(s)
        map[s] = i
        return i
    }

    struct FileRef {
        let url: URL
        let project: String
        let session: String
    }

    /// 디렉터리 구조는 다음 두 가지다.
    ///   <프로젝트>/<세션UUID>.jsonl                      ← 메인 세션
    ///   <프로젝트>/<세션UUID>/subagents/agent-*.jsonl    ← 서브에이전트 (+ tool-results 등)
    /// 따라서 프로젝트는 항상 첫 번째 경로 요소, 세션은 두 번째 요소로 잡아야
    /// 서브에이전트 사용량이 "subagents" 라는 가짜 프로젝트로 새지 않고 부모 세션에 합산된다.
    private static func listJSONL(_ root: URL) -> [FileRef] {
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [FileRef] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var rel = String(path.dropFirst(rootPath.count))
            while rel.hasPrefix("/") { rel.removeFirst() }
            let comps = rel.split(separator: "/").map(String.init)
            guard comps.count >= 2 else { continue }
            var session = comps[1]
            if comps.count == 2, session.hasSuffix(".jsonl") { session = String(session.dropLast(6)) }
            out.append(FileRef(url: url, project: comps[0], session: session))
        }
        return out
    }

    // MARK: - 파일 1개 파싱

    private struct Row {
        var key: UInt64
        var ts: Int32
        var input: Int32 = 0
        var cw5: Int32 = 0
        var cw1: Int32 = 0
        var cr: Int32 = 0
        var out: Int32 = 0
        var model: String
    }

    private struct FileResult {
        var project: String
        var session: String
        var rows: [Row]
    }

    private static let kAssistant = Array(#""type":"assistant""#.utf8)
    private static let kUsage = Array(#""usage":{"#.utf8)
    private static let kMsgID = Array(#""id":"msg_"#.utf8)
    private static let kReqID = Array(#""requestId":""#.utf8)
    private static let kTimestamp = Array(#""timestamp":""#.utf8)
    private static let kModel = Array(#""model":""#.utf8)
    private static let kInput = Array(#""input_tokens":"#.utf8)
    private static let kCacheCreate = Array(#""cache_creation_input_tokens":"#.utf8)
    private static let kCacheRead = Array(#""cache_read_input_tokens":"#.utf8)
    private static let kOutput = Array(#""output_tokens":"#.utf8)
    private static let k1h = Array(#""ephemeral_1h_input_tokens":"#.utf8)
    private static let k5m = Array(#""ephemeral_5m_input_tokens":"#.utf8)

    private static func parseFile(_ ref: FileRef) -> FileResult {
        let project = ref.project, session = ref.session
        guard let data = try? Data(contentsOf: ref.url, options: .mappedIfSafe) else {
            return FileResult(project: project, session: session, rows: [])
        }
        var rows: [Row] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var lineStart = 0
            let n = buf.count
            var i = 0
            while i <= n {
                if i == n || buf[i] == 0x0A {
                    if i > lineStart, let row = parseLine(buf, lineStart, i) { rows.append(row) }
                    lineStart = i + 1
                }
                i += 1
            }
        }
        return FileResult(project: project, session: session, rows: rows)
    }

    private static func parseLine(_ b: UnsafeRawBufferPointer, _ lo: Int, _ hi: Int) -> Row? {
        guard find(b, kAssistant, lo, hi) >= 0 else { return nil }
        let uPos = find(b, kUsage, lo, hi)
        guard uPos >= 0 else { return nil }
        let uStart = uPos + kUsage.count

        // usage 객체 뒤쪽에는 동일 키를 반복하는 iterations 배열이 있으므로
        // usage 시작점 이후의 "첫" 매치만 사용한다 (= 최상위 값).
        var row = Row(key: 0, ts: 0, model: "unknown")
        if let v = intAfter(b, kInput, uStart, hi) { row.input = v }
        if let v = intAfter(b, kCacheRead, uStart, hi) { row.cr = v }
        if let v = intAfter(b, kOutput, uStart, hi) { row.out = v }
        let cw1 = intAfter(b, k1h, uStart, hi) ?? 0
        let cw5 = intAfter(b, k5m, uStart, hi) ?? 0
        if cw1 == 0 && cw5 == 0 {
            // cache_creation 세부 항목이 없는 옛 포맷은 총량을 5분 캐시로 계상.
            row.cw5 = intAfter(b, kCacheCreate, uStart, hi) ?? 0
        } else {
            row.cw1 = cw1
            row.cw5 = cw5
        }

        if let p = pos(b, kTimestamp, lo, hi) { row.ts = TimeUtil.parseISO(b, p) }
        if let p = pos(b, kModel, lo, hi) { row.model = string(b, p, hi) }

        // 중복 제거 키: message.id + requestId. 둘 다 없으면 uuid 로 대체.
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        if let p = pos(b, kMsgID, lo, hi) { h = hash(b, p, hi, seed: h) }  // "msg_" 뒤 본문
        if let p = pos(b, kReqID, lo, hi) { h = hash(b, p, hi, seed: h) }
        if h == 0xcbf2_9ce4_8422_2325 { h = hash(b, lo, min(hi, lo + 120), seed: h) }
        row.key = h
        return row
    }

    // MARK: - 바이트 유틸

    /// [lo, hi) 구간에서 needle 시작 위치. 없으면 -1.
    @inline(__always)
    private static func find(_ b: UnsafeRawBufferPointer, _ needle: [UInt8], _ lo: Int, _ hi: Int) -> Int {
        let n = needle.count
        let last = hi - n
        if last < lo { return -1 }
        let first = needle[0]
        var i = lo
        while i <= last {
            if b[i] == first {
                var j = 1
                while j < n && b[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return -1
    }

    /// needle 바로 뒤 위치. 없으면 nil.
    @inline(__always)
    private static func pos(_ b: UnsafeRawBufferPointer, _ needle: [UInt8], _ lo: Int, _ hi: Int) -> Int? {
        let p = find(b, needle, lo, hi)
        return p < 0 ? nil : p + needle.count
    }

    @inline(__always)
    private static func intAfter(_ b: UnsafeRawBufferPointer, _ needle: [UInt8], _ lo: Int, _ hi: Int) -> Int32? {
        guard let p = pos(b, needle, lo, hi) else { return nil }
        var i = p
        var v: Int32 = 0
        var any = false
        while i < hi {
            let c = b[i]
            if c >= 48 && c <= 57 { v = v &* 10 &+ Int32(c - 48); i += 1; any = true } else { break }
        }
        return any ? v : nil
    }

    /// 닫는 따옴표까지의 문자열.
    @inline(__always)
    private static func string(_ b: UnsafeRawBufferPointer, _ p: Int, _ hi: Int) -> String {
        var i = p
        while i < hi && b[i] != 0x22 { i += 1 }
        guard i > p else { return "" }
        let bytes = UnsafeRawBufferPointer(rebasing: b[p..<i])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 닫는 따옴표까지 FNV-1a.
    @inline(__always)
    private static func hash(_ b: UnsafeRawBufferPointer, _ p: Int, _ hi: Int, seed: UInt64) -> UInt64 {
        var h = seed
        var i = max(0, p)
        while i < hi && b[i] != 0x22 {
            h = (h ^ UInt64(b[i])) &* 0x0000_0100_0000_01B3
            i += 1
        }
        return h
    }
}
