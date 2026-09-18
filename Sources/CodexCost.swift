import Foundation

// MARK: - Codex 비용 계산
//
// Claude 쪽 Price 와 분리한다. 토큰 의미가 달라 합치면 이중 계상이 생긴다
// (Codex: total = input + output, cached ⊂ input, reasoning ⊂ output).
// 요율표는 2026-09-18 확인 OpenAI 공개 요금이다.
// gpt-5.6-sol 은 2026-11-21까지 할인($4/$20), 2026-11-22부터 정가($5/$30).
// 날짜 기준은 기기 로컬 일자(스캐너의 day 번호와 같은 기준)다.
// 캐시 읽기는 입력가의 0.1배, 추론 토큰은 출력에 포함돼 따로 더하지 않는다.
// cacheWrite 는 별도 과금 정보가 없어 비용에 넣지 않는다.
// 요율표에 없는 모델은 0원이다.
enum CodexCost {
    struct Rate { let input: Double; let output: Double }

    /// 할인 마지막 날(포함). 2026-11-21.
    static let promoLastDay: Int32 = Int32(TimeUtil.daysFromCivil(2026, 11, 21))

    static func rate(model: String, day: Int32) -> Rate? {
        if model.hasPrefix("gpt-5.6-sol") {
            return day <= promoLastDay
                ? Rate(input: 4, output: 20)
                : Rate(input: 5, output: 30)
        }
        if model.hasPrefix("gpt-5.5") { return Rate(input: 5, output: 30) }
        if model.hasPrefix("gpt-5.4-mini") { return Rate(input: 0.75, output: 4.5) }
        if model.hasPrefix("gpt-5.4") { return Rate(input: 2.5, output: 15) }
        if model.hasPrefix("gpt-5.3-codex") { return Rate(input: 1.75, output: 14) }
        return nil
    }

    /// 요율표에 있는 모델 이름인가. 기간과 무관하게 같은 집합이다.
    static func isKnown(_ model: String) -> Bool {
        model.hasPrefix("gpt-5.6-sol") || model.hasPrefix("gpt-5.5")
            || model.hasPrefix("gpt-5.4") || model.hasPrefix("gpt-5.3-codex")
    }

    /// 달러. cached 는 input 의 일부라 fresh 분만 정가, cached 분은 0.1배.
    static func cost(input: Int64, cached: Int64, output: Int64, model: String, day: Int32) -> Double {
        guard let r = rate(model: model, day: day) else { return 0 }
        let m = 1.0 / 1_000_000.0
        let cached = max(Int64(0), cached)
        let fresh = max(Int64(0), input - cached)
        return (Double(fresh) * r.input + Double(cached) * r.input * 0.1
            + Double(max(Int64(0), output)) * r.output) * m
    }

    static func cost(of r: CodexRec, names: [String]) -> Double {
        guard r.model >= 0, Int(r.model) < names.count else { return 0 }
        return cost(input: Int64(r.input), cached: Int64(r.cached), output: Int64(r.output),
                    model: names[Int(r.model)], day: r.day)
    }

    private static func match(_ snap: CodexSnapshot, plan: Int32?) -> [CodexRec] {
        guard let plan else { return snap.records }
        return snap.records.filter { $0.plan == plan }
    }

    /// [from, to] 일자 합산 비용. 요율표 밖 모델은 0원 기여.
    static func rangeCost(_ snap: CodexSnapshot, plan: Int32?, from: Int32, to: Int32) -> Double {
        var sum = 0.0
        for r in match(snap, plan: plan) where r.day >= from && r.day <= to {
            sum += cost(of: r, names: snap.models)
        }
        return sum
    }

    /// 전체 기간 합산 비용 (plan nil = 전체 플랜, 미상 플랜 포함).
    static func totalCost(_ snap: CodexSnapshot, plan: Int32?) -> Double {
        var sum = 0.0
        for r in match(snap, plan: plan) { sum += cost(of: r, names: snap.models) }
        return sum
    }

    /// 모델명 → 비용. 요율표 밖 모델은 키 자체가 없다(순위에서 제외용).
    static func costByModelName(_ snap: CodexSnapshot, plan: Int32?) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in match(snap, plan: plan) {
            guard r.model >= 0, Int(r.model) < snap.models.count else { continue }
            let name = snap.models[Int(r.model)]
            let c = cost(input: Int64(r.input), cached: Int64(r.cached), output: Int64(r.output),
                         model: name, day: r.day)
            if c > 0 { out[name, default: 0] += c }
        }
        return out
    }

    /// 프로젝트 경로 → 비용. 모델 미상 기록도 프로젝트 귀속은 유효해 0원 기여로 포함된다.
    static func costByProjectPath(_ snap: CodexSnapshot, plan: Int32?) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in match(snap, plan: plan) {
            guard r.project >= 0, Int(r.project) < snap.projects.count else { continue }
            let c = cost(of: r, names: snap.models)
            if c > 0 { out[snap.projects[Int(r.project)], default: 0] += c }
        }
        return out
    }

    /// 요율표에 없는 모델의 토큰 비중 (모델 미상 포함, 분모는 전체). 0~1.
    static func unpricedShare(_ snap: CodexSnapshot, plan: Int32?) -> Double {
        var all: Int64 = 0, unk: Int64 = 0
        for r in match(snap, plan: plan) {
            all += r.total
            let name = (r.model >= 0 && Int(r.model) < snap.models.count)
                ? snap.models[Int(r.model)] : ""
            if !isKnown(name) { unk += r.total }
        }
        return all > 0 ? Double(unk) / Double(all) : 0
    }

    /// 모델 이름 자체가 없는 기록의 토큰 비중 (분모는 전체). 0~1.
    static func unknownShare(_ snap: CodexSnapshot, plan: Int32?) -> Double {
        var all: Int64 = 0, unk: Int64 = 0
        for r in match(snap, plan: plan) {
            all += r.total
            let name = (r.model >= 0 && Int(r.model) < snap.models.count)
                ? snap.models[Int(r.model)] : ""
            if name.isEmpty || name == "unknown" { unk += r.total }
        }
        return all > 0 ? Double(unk) / Double(all) : 0
    }
}
