import SwiftUI
import Charts

struct OverviewView: View {
    let snap: Snapshot
    let limits: DerivedLimits
    let config: Config
    var official: OfficialUsage? = nil
    var officialNote: String = ""

    private var today: Int32 { TimeUtil.todayDay() }
    private var todayTotals: Totals { snap.totals(fromDay: today, toDay: today) }
    private var monthTotals: Totals { snap.totals(fromDay: TimeUtil.startOfMonthDay(), toDay: today) }
    // 한도는 출력 토큰 기준(Claude 동일 단위)이므로 소모 속도도 출력만.
    private var burn: Double { snap.burnRate(minutes: 15, outputOnly: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            unitBanner(text: official != nil
                       ? "실시간 한도 — 공식 사용률 직접 연결 (계정 전체) · 토큰 수치는 로컬 로그"
                       : "실시간 한도 — 출력 토큰 근사 · 공식 사용률(%) 앵커로 보정 (정본은 Claude 설정)",
                       color: Theme.green)
            kpiRow
            LimitStatusCard(snap: snap, burn: burn, limits: limits, config: config,
                            official: official, officialNote: officialNote)
            unitBanner(text: "사용 분석 — 총 처리 토큰 (입력·캐시·출력 전부, 캐시읽기 포함). '어디에 얼마나 썼나' 용도",
                       color: Theme.teal)
            StackedDailyCard(snap: snap)
            DailyTotalCard(snap: snap)
            YearSummaryCard(snap: snap)
            footnote
        }
    }

    private func unitBanner(text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 13)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            Spacer()
        }
    }

    private var kpiRow: some View {
        let now = Int32(Date().timeIntervalSince1970)
        let block = snap.activeBlock

        // 공식 % 우선, 없으면 로컬 출력/한도 추정
        let fiveUse = block?.totals.output ?? 0
        let fiveLocal = limits.fiveHour > 0 ? Double(fiveUse) / Double(limits.fiveHour) : 0
        let fivePct = official?.fiveHour.map { $0.utilization / 100 } ?? fiveLocal
        let fiveIsOfficial = official?.fiveHour != nil

        let (ws, _) = snap.weeklyWindow(config, now: now)
        let weekUse = snap.usageRange(from: ws, to: now).output
        let weekLocal = limits.weeklyAll > 0 ? Double(weekUse) / Double(limits.weeklyAll) : 0
        let weekPct = official?.week.map { $0.utilization / 100 } ?? weekLocal
        let weekIsOfficial = official?.week != nil

        return HStack(spacing: 12) {
            StatTile(label: "5시간 사용률" + (fiveIsOfficial ? " · 공식" : ""),
                     value: (fiveIsOfficial || (block != nil && limits.fiveHour > 0)) ? Fmt.percent(fivePct) : "–",
                     caption: block == nil ? "활성 블록 없음(로컬)"
                        : "로컬 출력 \(Fmt.tokens(fiveUse))" + (fiveIsOfficial ? " · 추정 \(Fmt.percent(fiveLocal))" : ""),
                     valueColor: warn(fivePct, base: Theme.green))
            StatTile(label: "소모 속도 (최근 15분)",
                     value: burn > 0 ? Fmt.tokens(burn) : "0",
                     caption: "출력 토큰/분")
            StatTile(label: "주간 사용률" + (weekIsOfficial ? " · 공식" : ""),
                     value: (weekIsOfficial || limits.weeklyAll > 0) ? Fmt.percent(weekPct) : "–",
                     caption: weekIsOfficial
                        ? "계정 전체 · 로컬 추정 \(Fmt.percent(weekLocal))"
                        : (limits.weeklyAll > 0 ? "남은 \(Fmt.tokens(max(0, limits.weeklyAll - weekUse)))" : "한도 미설정"),
                     valueColor: warn(weekPct, base: Theme.teal))
            StatTile(label: "오늘 (총 처리)",
                     value: Fmt.tokens(todayTotals.total),
                     caption: "\(Fmt.usd(todayTotals.cost)) · 출력 \(Fmt.tokens(todayTotals.output))")
            StatTile(label: "이번 달 (총 처리)",
                     value: Fmt.tokens(monthTotals.total),
                     caption: Fmt.usd(monthTotals.cost))
        }
    }

    private func warn(_ p: Double, base: Color) -> Color {
        p > 0.85 ? Theme.red : (p > 0.6 ? Theme.orange : base)
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("파일 \(Fmt.decimal(Int64(snap.scannedFiles)))개 · 원본 \(Fmt.decimal(Int64(snap.rawLines)))줄에서 중복 \(Fmt.decimal(Int64(snap.duplicatesDropped)))줄 제거 → 고유 요청 \(Fmt.decimal(Int64(snap.grand.requests)))건 · 스캔 \(String(format: "%.1f", snap.scanSeconds))초")
            Text("한 번의 API 응답이 content block 수만큼 여러 줄로 기록되고 각 줄이 같은 usage 를 복사해 갖기 때문에, (message.id + requestId) 기준으로 중복을 제거합니다. 다만 output_tokens 만은 마지막 줄에 최종값이 실리므로 그룹 내 최대값을 채택합니다.")
            Text("비용은 공개 요율(캐시 쓰기 5분 1.25x / 1시간 2x, 캐시 읽기 0.1x)로 계산한 추정치이며 Sonnet 5 는 도입가($2/$10)를 적용했습니다.")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.faint)
        .padding(.top, 2)
    }
}

// MARK: - 실시간 한도 현황 (5시간 블록 + 주간 전체 + 주간 Fable)

/// 게이지 한 칸의 표시 데이터. pct 는 1.0 을 넘을 수 있고, 넘으면 경고색으로 바뀐다.
private struct GaugeSpec {
    let title: String
    let subtitle: String
    let pct: Double
    let center: String       // 링 중앙 큰 값 (퍼센트)
    let centerSub: String    // 링 중앙 작은 값 (토큰)
    let base: Color
    let valueLine: String    // "4,656만 / 4.6억"
    let refLine: String      // "역대 최대 블록 대비"
    let rows: [(String, String)]
    var muted: Bool = false  // 데이터 없음(비활성) 상태
    var timeFraction: Double = 0  // 윈도우 경과 비율 (0~1) — 바깥 링용

    var color: Color {
        if muted { return Theme.faint }
        return pct > 0.85 ? Theme.red : (pct > 0.6 ? Theme.orange : base)
    }

    /// 바깥 시간 링 색. 사용률이 경과 시간 비율을 앞서면(과속) 경고색.
    var paceColor: Color {
        if muted { return Theme.faint }
        return pct > timeFraction + 0.03 ? Theme.orange : Theme.dim
    }
}

private struct LimitStatusCard: View {
    let snap: Snapshot
    let burn: Double
    let limits: DerivedLimits
    let config: Config
    var official: OfficialUsage? = nil
    var officialNote: String = ""

    var body: some View {
        let now = Int32(Date().timeIntervalSince1970)
        return CardBox {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "실시간 한도 현황",
                             trailing: official != nil
                                ? "\(config.plan) · 공식 사용률 연결됨"
                                : "\(config.plan) · 5시간 블록 · 주간(목 리셋)")
                Text("굵은 안쪽 링 = 한도 사용률 · 얇은 바깥 링 = 이번 윈도우 경과 시간 — 바깥 링보다 안쪽 링이 더 차 있으면 리셋 전에 소진될 속도입니다.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                HStack(alignment: .top, spacing: 14) {
                    gaugeColumn(blockSpec(now: now))
                    Divider().overlay(Theme.border).frame(height: 232)
                    gaugeColumn(weeklySpec(now: now, fableOnly: false))
                    Divider().overlay(Theme.border).frame(height: 232)
                    gaugeColumn(weeklySpec(now: now, fableOnly: true))
                }
                modelStrip
                caption
            }
        }
    }

    private var caption: some View {
        return VStack(alignment: .leading, spacing: 3) {
            if let official {
                let age = Int(Date().timeIntervalSince(official.fetchedAt) / 60)
                Text("공식 사용률 연결됨 (\(official.sourceNote) · \(age)분 전 갱신 · 30분 주기+백오프 폴링 · ⌘R 즉시 갱신). 게이지 %와 리셋 시각은 Claude 계정 정본이고, 토큰 수치는 로컬 로그 기준입니다."
                     + (official.otherKeys.isEmpty ? "" : " 미분류 버킷: \(official.otherKeys.joined(separator: ", "))"))
                    .font(.system(size: 11)).foregroundStyle(Theme.green.opacity(0.9))
                if !official.sourceNote.contains("전용 토큰") {
                    Text("지금은 실행 중인 세션의 토큰을 빌려 쓰는 중 — 세션을 모두 닫으면 끊깁니다. 상시 연결: claude setup-token 발급 후 README 의 Keychain 등록 한 줄 (항목명 ClaudeUsageDashboard-token).")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            } else {
                Text("공식 사용률 미연결(\(officialNote)) — Claude 세션이 실행 중이면 자동 연결됩니다. 아래는 보정 추정치입니다.")
                    .font(.system(size: 11)).foregroundStyle(Theme.orange.opacity(0.9))
            }
            Text("한도는 공식 사용률(%)을 출력 토큰으로 역산한 근사치입니다 — 주간 ≈16.2M(87% 앵커 + 7월 일별 대조로 확인된 타 기기 사용 보정) · 5시간 4.33M(37% 앵커, 출근일이라 이 기기 단독) · Fable ≥2.46M(로컬 관측 하한 — 같은 주 집 기기 Fable 사용분만큼 실제 캡은 더 클 수 있음).")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("주의: 이 앱은 이 컴퓨터의 로그만 봅니다. 7월 실측상 주말·저녁에 집 기기/모바일 사용이 있어(월 계정의 ~15-20%), 그런 날은 주간 %가 공식보다 낮게 보입니다. 집 기기 로그를 복사해 extraRoots 에 넣으면 합산되고, \(Config.fileURL.path) 에서 값을 고칠 수 있습니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text("Fable 정책은 '주간 한도의 최대 50%'지만 실측 도달점은 단위에 따라 주간의 20%(출력)~30%(비용)입니다. 간극의 원인(낮은 실효 캡 vs Fable 가중 계량)은 로그만으로 판별 불가 — 게이지는 실측 절대량(2.46M)을 분모로 쓰므로 추적에는 지장 없습니다.")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
        .padding(.top, 2)
    }

    // MARK: 5시간 블록 게이지

    private func blockSpec(now: Int32) -> GaugeSpec {
        let off = official?.fiveHour
        let b = snap.activeBlock
        if b == nil && off == nil {
            let last = snap.records.last.map {
                TimeUtil.dayString(TimeUtil.localDay($0.ts)) + " " + TimeUtil.clockString($0.ts) } ?? "-"
            return GaugeSpec(title: "5시간 블록", subtitle: "활성 블록 없음", pct: 0,
                             center: "–", centerSub: "", base: Theme.green,
                             valueLine: "진행 중인 블록 없음", refLine: "마지막 활동 \(last)",
                             rows: [], muted: true)
        }
        let used = Int64(b?.totals.output ?? 0)   // 로컬 출력 토큰
        let ref = limits.fiveHour
        let localPct = ref > 0 ? Double(used) / Double(ref) : 0
        let p = off.map { $0.utilization / 100 } ?? localPct

        // 리셋 시각: 공식 resets_at 우선 (다른 기기가 블록을 연 경우 로컬 추정이 어긋남)
        let end = off?.resetsAt ?? b?.end ?? now
        let remainSec = max(0, Int(end) - Int(now))
        let windowSec = 5 * 3600
        let timeFrac = min(1, max(0, 1.0 - Double(remainSec) / Double(windowSec)))
        let projPct = p + (ref > 0 ? burn * Double(remainSec) / 60.0 / Double(ref) : 0)
        let depleted = p >= 1.0

        var rows: [(String, String)] = []
        rows.append(("남은 여유", depleted ? "소진 (0)"
                     : (ref > 0 ? Fmt.tokens(max(0, Int64((1.0 - p) * Double(ref)))) : "-")))
        rows.append(("리셋까지", TimeUtil.duration(seconds: remainSec) + " (시간 \(Fmt.percent(timeFrac)) 경과)"))
        rows.append(("리셋 시각", TimeUtil.resetLabel(Int32(end))))
        if off != nil, ref > 0 {
            rows.append(("로컬 추정", Fmt.percent(localPct)))
        } else {
            rows.append(depleted ? ("상태", "한도 소진") : ("리셋 시 예상", Fmt.percent(projPct)))
        }

        return GaugeSpec(
            title: "5시간 블록",
            subtitle: off != nil ? "공식 · 계정 전체"
                : (b.map { "\(TimeUtil.clockString($0.start)) – \(TimeUtil.clockString($0.end))" } ?? ""),
            pct: p, center: Fmt.percent(p), centerSub: "로컬 출력 \(Fmt.tokens(used))", base: Theme.green,
            valueLine: ref > 0 ? "\(Fmt.tokens(Int64(p * Double(ref)))) / \(Fmt.tokens(ref))" : "출력 \(Fmt.tokens(used))",
            refLine: off != nil ? "공식 사용률 × 추정한도 \(Fmt.tokens(ref))"
                : (ref > 0 ? "\(config.plan) 5시간 한도 (출력)" : "한도 미설정"),
            rows: rows, timeFraction: timeFrac)
    }

    // MARK: 주간 게이지 (전체 / Fable)

    private func weeklySpec(now: Int32, fableOnly: Bool) -> GaugeSpec {
        let off = fableOnly ? official?.fable : official?.week
        let (ws, weLocal) = snap.weeklyWindow(config, now: now)
        let used = snap.usageRange(from: ws, to: now, fableOnly: fableOnly)
        let base = fableOnly ? Theme.blue : Theme.teal
        let title = fableOnly ? "주간 · Fable" : "주간 · 전체"
        let we = off?.resetsAt ?? weLocal
        let subtitle = off != nil ? "공식 · 계정 전체 → \(TimeUtil.resetLabel(Int32(we)))"
            : "\(TimeUtil.shortDayString(TimeUtil.localDay(ws))) → \(TimeUtil.resetLabel(we))"

        let usedOut = Int64(used.output)   // 로컬 출력 토큰
        let ownLimit = fableOnly ? limits.weeklyFable : limits.weeklyAll
        let ref = ownLimit
        let localPct = ref > 0 ? Double(usedOut) / Double(ref) : 0

        guard off != nil || ref > 0 else {
            return GaugeSpec(title: title, subtitle: subtitle, pct: 0, center: "–", centerSub: "",
                             base: base, valueLine: fableOnly ? "Fable 기록 없음" : "한도 미설정",
                             refLine: "한도 미설정", rows: [], muted: true)
        }

        let p = off.map { $0.utilization / 100 } ?? localPct
        let depleted = p >= 1.0
        let remainSec = max(0, Int(we) - Int(now))
        let elapsed = max(1, Int(now) - Int(ws))
        let windowSec = 7 * 24 * 3600
        let timeFrac = min(1, max(0, Double(elapsed) / Double(windowSec)))
        let projPct = p * Double(7 * 24 * 3600) / Double(elapsed)

        var rows: [(String, String)] = []
        rows.append(("남은 여유", depleted ? "소진 (0)"
                     : (ref > 0 ? Fmt.tokens(max(0, Int64((1.0 - p) * Double(ref)))) : "-")))
        rows.append(("리셋까지", TimeUtil.duration(seconds: remainSec) + " (시간 \(Fmt.percent(timeFrac)) 경과)"))
        rows.append(("주 비용(로컬)", Fmt.usd(used.cost)))
        if off != nil, ref > 0 {
            rows.append(("로컬 추정", Fmt.percent(localPct)))
        } else if depleted {
            rows.append(("상태", "한도 소진"))
        } else if Double(elapsed) < 0.1 * Double(7 * 24 * 3600) {
            // 창 초반의 선형 외삽은 수천 % 같은 노이즈만 만든다
            rows.append(("리셋 시 예상", "표본 부족"))
        } else {
            rows.append(("리셋 시 예상", Fmt.percent(projPct)))
        }

        let refLine: String
        if off != nil {
            refLine = ref > 0 ? "공식 사용률 × 추정한도 \(Fmt.tokens(ref))" : "공식 사용률 · 계정 전체"
        } else {
            refLine = fableOnly ? "\(config.plan) Fable 주간 한도 (출력)" : "\(config.plan) 주간 한도 (출력)"
        }
        return GaugeSpec(
            title: title, subtitle: subtitle,
            pct: p, center: Fmt.percent(p),
            centerSub: "로컬 출력 \(Fmt.tokens(usedOut))", base: base,
            valueLine: ref > 0 ? "\(Fmt.tokens(Int64(p * Double(ref)))) / \(Fmt.tokens(ref))" : "공식 \(Fmt.percent(p))",
            refLine: refLine, rows: rows, timeFraction: timeFrac)
    }

    // MARK: 렌더링

    private func gaugeColumn(_ s: GaugeSpec) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(s.subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            ring(s)
            VStack(spacing: 3) {
                Text(s.valueLine).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(s.muted ? Theme.dim : Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(s.refLine).font(.system(size: 10)).foregroundStyle(Theme.faint)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            VStack(spacing: 5) {
                ForEach(s.rows, id: \.0) { label, value in
                    HStack {
                        Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    }
                }
            }
            .frame(minHeight: 78, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    /// 바깥 얇은 링 = 이번 윈도우의 경과 시간 비율, 안쪽 굵은 링 = 한도 사용률.
    /// 두 링을 겹쳐 보면 "시간이 가는 속도"와 "한도가 줄어드는 속도"를 한눈에 비교할 수 있다.
    private func ring(_ s: GaugeSpec) -> some View {
        ZStack {
            if !s.muted {
                Circle().inset(by: -12)
                    .stroke(Theme.cardAlt.opacity(0.7), lineWidth: 3)
                Circle().inset(by: -12)
                    .trim(from: 0, to: min(1, s.timeFraction))
                    .stroke(s.paceColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle().stroke(Theme.cardAlt, lineWidth: 12)
            Circle()
                .trim(from: 0, to: min(1, s.pct))
                .stroke(s.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if s.pct > 1 {   // 100% 초과분은 안쪽 얇은 빨간 링
                Circle().inset(by: 9)
                    .trim(from: 0, to: min(1, s.pct - 1))
                    .stroke(Theme.red.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(s.center).font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(s.muted ? Theme.dim : Theme.text)
                if !s.centerSub.isEmpty {
                    Text(s.centerSub).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(width: 116, height: 116)
        .padding(14)
    }

    @ViewBuilder private var modelStrip: some View {
        if let b = snap.activeBlock {
            let items = b.byModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5)
            if !items.isEmpty {
                HStack(spacing: 14) {
                    Text("현재 블록 모델").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    ForEach(Array(items), id: \.key) { key, value in
                        let name = snap.models[Int(key)]
                        HStack(spacing: 6) {
                            Circle().fill(Theme.color(model: name)).frame(width: 7, height: 7)
                            Text(Fmt.modelShort(name)).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                            Text(Fmt.tokens(value)).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }
}

// MARK: - 모델별 일간 사용량 (스택)

struct DayModelPoint: Identifiable {
    let id: String
    let date: Date
    let model: String
    let tokens: Int64
}

private struct StackedDailyCard: View {
    let snap: Snapshot

    private var points: [DayModelPoint] {
        snap.dailyByModelSeries(lastDays: 30).map {
            DayModelPoint(id: "\($0.day)-\($0.model)",
                          date: TimeUtil.startOfLocalDay($0.day),
                          model: $0.model, tokens: $0.tokens)
        }
    }

    private var modelOrder: [String] {
        snap.rankedModels().map(\.name)
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "모델별 일간 사용량 (스택)", trailing: "최근 30일")
                Chart(points) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day),
                            y: .value("토큰", p.tokens))
                        .foregroundStyle(by: .value("모델", p.model))
                }
                .chartForegroundStyleScale(domain: modelOrder,
                                           range: modelOrder.map { Theme.color(model: $0) })
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .chartYAxis { tokenAxis() }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 5)) { value in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(),
                                       centered: false)
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 260)
            }
        }
    }
}

// MARK: - 일별 총 토큰

private struct DailyTotalCard: View {
    let snap: Snapshot

    private struct P: Identifiable { let id: Int32; let date: Date; let tokens: Int64; let cost: Double }

    private var points: [P] {
        snap.dailySeries().map {
            P(id: $0.day, date: TimeUtil.startOfLocalDay($0.day),
              tokens: $0.totals.total, cost: $0.totals.cost)
        }
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "일별 토큰 사용량",
                             trailing: "\(points.count)일 · 일평균 \(Fmt.tokens(avg))")
                Chart(points) { p in
                    AreaMark(x: .value("날짜", p.date), y: .value("토큰", p.tokens))
                        .foregroundStyle(.linearGradient(
                            colors: [Theme.green.opacity(0.45), Theme.green.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("날짜", p.date), y: .value("토큰", p.tokens))
                        .foregroundStyle(Theme.green)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                }
                .chartYAxis { tokenAxis() }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private var avg: Int64 {
        points.isEmpty ? 0 : points.reduce(Int64(0)) { $0 + $1.tokens } / Int64(points.count)
    }
}

// MARK: - 연간 요약

private struct YearSummaryCard: View {
    let snap: Snapshot

    var body: some View {
        let g = snap.grand
        return CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "연간 합계",
                             trailing: "\(Fmt.decimal(Int64(g.requests)))건 요청 · \(Fmt.usd(g.cost))")
                HStack(spacing: 10) {
                    breakdown("입력", g.input, Theme.blue)
                    breakdown("캐시 쓰기 5분", g.cacheWrite5m, Theme.teal)
                    breakdown("캐시 쓰기 1시간", g.cacheWrite1h, Theme.purple)
                    breakdown("캐시 읽기", g.cacheRead, Theme.green)
                    breakdown("출력", g.output, Theme.orange)
                    breakdown("합계", g.total, Theme.text)
                }
            }
        }
    }

    private func breakdown(_ label: String, _ value: Int64, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 11)
                Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            Text(Fmt.tokens(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(Fmt.decimal(value)).font(.system(size: 10)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardAlt))
    }
}

// MARK: - 공용 축

@AxisContentBuilder
func tokenAxis() -> some AxisContent {
    AxisMarks(position: .leading) { value in
        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
        AxisValueLabel {
            if let v = value.as(Double.self) {
                Text(Fmt.axis(Int64(v))).foregroundStyle(Theme.dim)
            }
        }
    }
}
