import Foundation

/// Anthropic 공식 사용률 API (Claude Code 의 /usage 가 쓰는 OAuth 엔드포인트) 직접 조회.
///
/// Tuner 의 원리(공식 % 스냅샷)를 추정 토큰 변환 없이 그대로 쓰는 완성형:
/// 계정 전체(모든 기기+웹)의 정확한 %와 리셋 시각을 얻는다. 게이지의 정본이 되고,
/// 로컬 로그는 "무엇이/어디서 썼나"의 세부를 채운다.
///
/// 토큰 출처 (읽기 전용, 어디에도 기록하지 않음):
///   1. 실행 중인 Claude 프로세스 환경변수 CLAUDE_CODE_OAUTH_TOKEN (데스크톱/CLI 세션이 떠 있으면 존재)
///   2. Keychain "Claude Code-credentials" (만료 검사 통과 시)
struct OfficialBucket {
    var utilization: Double      // 0~100 (%)
    var resetsAt: Int32?         // epoch 초
    var rawKey: String
}

struct OfficialUsage {
    var fiveHour: OfficialBucket?
    var week: OfficialBucket?
    var fable: OfficialBucket?
    var otherKeys: [String] = []
    var fetchedAt = Date()
    var sourceNote: String = ""
}

struct OfficialError: Error { let message: String }

enum OfficialAPI {
    static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    // MARK: 토큰 확보

    /// 직전 폴링에서 성공한 토큰 (같은 프로세스 생존 동안 우선 시도).
    private static var lastWorking: String?

    /// 토큰 후보를 신뢰도 순으로 전부 모은다. 데스크톱 세션이 여러 날 쌓이면 만료 토큰을 가진
    /// 옛 프로세스가 공존하므로(실측: 나흘간 5종), 단일 선택이 아니라 후보 체인이 필요하다.
    static func findTokenCandidates() -> [(token: String, note: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        func add(_ t: String?, _ note: String) {
            guard let t, !t.isEmpty, seen.insert(t).inserted else { return }
            out.append((t, note))
        }
        add(lastWorking, "직전 성공 토큰")
        add(tokenFromOwnKeychain(), "전용 토큰(setup-token)")
        for (i, t) in tokensFromProcesses().enumerated() {
            add(t, i == 0 ? "실행 중 Claude 세션(최신)" : "실행 중 Claude 세션(이전 #\(i + 1))")
        }
        add(tokenFromKeychain(), "Keychain")
        return out
    }

    static func markWorking(_ token: String) { lastWorking = token }
    static func invalidateWorking() { lastWorking = nil }

    /// 사용자가 `claude setup-token` 으로 발급해 직접 등록한 장수명 토큰 (최우선).
    /// 등록:  security add-generic-password -a "$USER" -s ClaudeUsageDashboard-token \
    ///         -w "$(pbpaste | tr -cd 'A-Za-z0-9_-')" -U
    /// 실행 중인 세션에 기대지 않아 Claude 를 꺼도 공식 % 연결이 유지된다.
    ///
    /// 붙여넣기 사고 자가치유: 터미널에서 줄바꿈된 토큰을 복사하면 중간에 개행이 끼고,
    /// 비인쇄 바이트가 섞이면 security 가 값 전체를 hex 로 출력한다 (실제 발생한 장애).
    /// → hex 복원 후 토큰 문자만 이어붙여 원형을 되살린다.
    private static func tokenFromOwnKeychain() -> String? {
        var out = shell("security find-generic-password -s 'ClaudeUsageDashboard-token' -w 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count >= 80, out.count % 2 == 0,
           out.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(out.count / 2)
            var i = out.startIndex
            while i < out.endIndex {
                let j = out.index(i, offsetBy: 2)
                bytes.append(UInt8(out[i..<j], radix: 16) ?? 0)
                i = j
            }
            out = String(decoding: bytes, as: UTF8.self)
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        out = String(out.filter { allowed.contains($0) })
        return (out.hasPrefix("sk-ant-") && out.count >= 90) ? out : nil
    }

    private static func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// 실행 중인 모든 claude 프로세스에서 토큰을 모아 **프로세스가 젊은 순**으로 반환 (최대 4종).
    /// PID 순서(pgrep 기본)는 가장 오래된 세션 = 만료 토큰을 먼저 주므로 절대 쓰면 안 된다.
    private static func tokensFromProcesses() -> [String] {
        let script = #"""
        for pid in $(pgrep -f claude); do
          t=$(ps eww $pid 2>/dev/null | tr ' ' '\n' | grep '^CLAUDE_CODE_OAUTH_TOKEN=' | head -1 | cut -d= -f2)
          [ -n "$t" ] && echo "$(ps -o etimes= -p $pid 2>/dev/null | tr -d ' ') $t"
        done | sort -n
        """#
        var seen = Set<String>()
        var out: [String] = []
        for line in shell(script).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let t = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard t.count > 20, seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count >= 4 { break }
        }
        return out
    }

    /// Keychain 항목 (Claude Code CLI 가 관리). 만료면 nil.
    private static func tokenFromKeychain() -> String? {
        let out = shell("security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null")
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = (obj["claudeAiOauth"] as? [String: Any]) ?? obj as [String: Any]?,
              let token = oauth["accessToken"] as? String, token.count > 20 else { return nil }
        if let exp = oauth["expiresAt"] as? Double, exp < Date().timeIntervalSince1970 * 1000 {
            return nil
        }
        return token
    }

    // MARK: 조회

    /// 동기 조회 (백그라운드 큐에서 호출할 것).
    /// 후보 토큰을 신선한 순으로 시도한다. 인증 실패(만료 토큰)면 다음 후보로 넘어가고,
    /// 429(레이트리밋)·네트워크 오류는 토큰 문제가 아니므로 즉시 중단해 호출량을 아낀다.
    static func fetchSync() -> Result<OfficialUsage, OfficialError> {
        let candidates = findTokenCandidates()
        guard !candidates.isEmpty else {
            return .failure(OfficialError(message: "토큰 없음 — Claude 세션이 실행 중이면 자동 연결됩니다"))
        }
        var authFails = 0
        for (token, note) in candidates {
            switch request(token: token) {
            case .ok(let body):
                guard let usage = parse(body, note: note) else {
                    return .failure(OfficialError(message: "파싱 실패"))
                }
                markWorking(token)
                return .success(usage)
            case .authFailure:
                authFails += 1
                if token == lastWorking { invalidateWorking() }
                continue
            case .stop(let msg):
                return .failure(OfficialError(message: msg))
            }
        }
        return .failure(OfficialError(message: "토큰 후보 \(authFails)개 전부 만료 — Claude 데스크톱을 재시작하거나 setup-token 을 등록하세요"))
    }

    private enum RequestOutcome {
        case ok(Data)
        case authFailure          // 401/403 → 다음 후보 시도
        case stop(String)         // 429·네트워크 등 → 후보 순회 중단
    }

    private static func request(token: String) -> RequestOutcome {
        var req = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeUsageDashboard/1.0 (local)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var status = 0
        var netErr: String?
        URLSession.shared.dataTask(with: req) { d, r, e in
            body = d
            status = (r as? HTTPURLResponse)?.statusCode ?? 0
            netErr = e?.localizedDescription
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)

        if let netErr { return .stop("네트워크: \(netErr)") }
        guard let body else { return .stop("응답 없음") }
        if status == 200 { return .ok(body) }
        // 에러 본문에서 type 만 추출 (토큰 등 비밀값 없음)
        let type = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["type"] as? String } ?? "HTTP \(status)"
        if status == 401 || status == 403 || type.contains("authentication") || type.contains("permission") {
            return .authFailure
        }
        return .stop(type)
    }

    /// 실측 스키마(2026-07-23) 기준 파서.
    /// 정본은 `limits[]` 배열: {kind: session|weekly_all|weekly_scoped, percent, resets_at,
    /// scope.model.display_name("Fable")}. 톱레벨 five_hour/seven_day 는 보충용.
    static func parse(_ data: Data, note: String) -> OfficialUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out = OfficialUsage(sourceNote: note)

        func bucket(_ d: [String: Any], key: String) -> OfficialBucket? {
            guard let u = numeric(d["utilization"]) ?? numeric(d["percent"]) else { return nil }
            return OfficialBucket(utilization: u,
                                  resetsAt: (d["resets_at"] as? String).flatMap(parseISO),
                                  rawKey: key)
        }

        // 1) limits[] — kind + scope 로 분류
        for d in (obj["limits"] as? [[String: Any]]) ?? [] {
            let kind = ((d["kind"] as? String) ?? "").lowercased()
            let scopeName = ((((d["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"]) as? String)?.lowercased() ?? ""
            guard let b = bucket(d, key: scopeName.isEmpty ? kind : "\(kind):\(scopeName)") else { continue }
            if kind == "session" || kind.contains("five") {
                out.fiveHour = b
            } else if scopeName.contains("fable") || scopeName.contains("opus") || kind.contains("opus") {
                out.fable = b
            } else if kind == "weekly_all" || (kind.contains("week") && scopeName.isEmpty) {
                out.week = b
            } else {
                out.otherKeys.append(b.rawKey)
            }
        }

        // 2) 톱레벨 폴백 (limits 가 없거나 비는 필드 보충)
        for (k, v) in obj {
            if k == "limits" || k == "extra_usage" || k == "spend" { continue }  // 크레딧 지표 제외
            guard let d = v as? [String: Any], let b = bucket(d, key: k) else { continue }
            let lk = k.lowercased()
            if lk.contains("five") || lk.contains("session") {
                if out.fiveHour == nil { out.fiveHour = b }
            } else if lk.contains("opus") || lk.contains("fable") || lk.contains("sota") {
                if out.fable == nil { out.fable = b }
            } else if lk == "seven_day" || lk.contains("week") {
                if out.week == nil { out.week = b }
            } else {
                out.otherKeys.append(k)
            }
        }
        return (out.fiveHour != nil || out.week != nil || out.fable != nil) ? out : nil
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private static func parseISO(_ s: String) -> Int32? {
        // 실제 응답은 마이크로초 6자리(".254192+00:00")인데 ISO8601DateFormatter 는
        // 3자리 밀리초만 읽으므로 소수부를 통째로 제거하고 파싱한다.
        var t = s
        if let r = t.range(of: #"\.\d+"#, options: .regularExpression) { t.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return Int32(d.timeIntervalSince1970) }
        return nil
    }
}
