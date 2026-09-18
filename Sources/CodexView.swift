import SwiftUI
import Charts

/// Codex 탭. Claude 탭들과 수치를 섞지 않는다 — 필드 의미가 다르기 때문
/// (Codex: total = input + output, cached ⊂ input).
struct CodexView: View {
    let snap: CodexSnapshot
    /// nil = 전체 합산, 값 = 특정 계정(플랜)만
    @State private var plan: Int32? = nil

    private var view: CodexSlice { snap.slice(plan) }
    private var today: Int32 { TimeUtil.todayDay() }
    private var todayT: CodexTotals { view.totals(fromDay: today, toDay: today) }
    private var monthT: CodexTotals { view.totals(fromDay: TimeUtil.startOfMonthDay(), toDay: today) }
    private var planName: String? { plan.map { snap.plans[Int($0)] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            accountPicker
            banner("실시간 한도 — Codex 로그에 기록된 공식 사용률 (API 호출 없음)", Theme.green)
            limitCard
            banner(planName == nil
                   ? "사용 분석 — 전체 계정 합산 · 총 처리 토큰(input+output). Claude 탭과 합산하지 않음"
                   : "사용 분석 — \(planName!) 계정만 · 총 처리 토큰(input+output)", Theme.teal)
            kpiRow
            HStack(alignment: .top, spacing: 18) {
                modelCard
                projectCard
            }
            dailyCard
            footnote
        }
    }

    /// 계정(플랜) 선택. 로그에 계정 식별자가 없어 plan_type 을 계정 대용으로 쓴다.
    private var accountPicker: some View {
        let opts = snap.planOptions()
        return HStack(spacing: 8) {
            Text("계정").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            chip(title: "전체", sub: Fmt.tokens(snap.all.grand.total), active: plan == nil) { plan = nil }
            ForEach(opts, id: \.index) { o in
                chip(title: o.name, sub: Fmt.tokens(o.totals.total),
                     active: plan == o.index,
                     badge: o.name == snap.account.planType ? "지금 로그인" : nil) { plan = o.index }
            }
            Spacer()
            if snap.account.loaded && !snap.account.email.isEmpty {
                Text("현재: \(snap.account.email)")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
    }

    private func chip(title: String, sub: String, active: Bool,
                      badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Theme.text)
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(active ? Color.white.opacity(0.85) : Theme.green)
                    }
                }
                Text(sub).font(.system(size: 10, design: .rounded))
                    .foregroundStyle(active ? Color.white.opacity(0.8) : Theme.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? Theme.teal : Theme.cardAlt))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(active ? Color.clear : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 13)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
            Spacer()
        }
    }

    // MARK: 한도 (로그 임베드 공식 사용률)

    private var limitCard: some View {
        let rl = planName.flatMap { snap.rateLimitsByPlan[$0] } ?? snap.rateLimits
        return CardBox {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: planName.map { "Codex 한도 — \($0) 계정" }
                                ?? "Codex 한도 — \(snap.account.label)",
                             trailing: rl.observedAt > 0 ? "\(rl.age) 기록" : "기록 없음")
                if snap.account.loaded && !snap.account.planType.isEmpty
                    && snap.rateLimitsByPlan[snap.account.planType] == nil {
                    Text("현재 계정(plan: \(snap.account.planType))의 한도 기록이 로그에 없어, 다른 플랜의 최신값을 보여줍니다 — 아래 게이지는 참고용입니다.")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange.opacity(0.9))
                }
                if rl.fiveHour == nil && rl.weekly == nil {
                    Text("로그에서 rate_limits 를 찾지 못했습니다. Codex 를 한 번 사용하면 기록됩니다.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.dim).padding(.vertical, 24)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        gauge("5시간", rl.fiveHour, Theme.green)
                        Divider().overlay(Theme.border).frame(height: 190)
                        gauge("7일", rl.weekly, Theme.teal)
                        Divider().overlay(Theme.border).frame(height: 190)
                        recentStrip
                    }
                    otherPlans
                    Text("이 %는 Codex 가 응답마다 로그에 남긴 계정 공식 수치이며, **지금 로그인된 계정의 플랜**(\(snap.account.planType.isEmpty ? "-" : snap.account.planType)) 기록만 골라 씁니다. 마지막 사용 시점의 값이라 그 뒤 다른 기기에서 쓴 분량은 반영되지 않습니다.")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Text("주의: 세션 로그에는 계정 식별자가 없어 플랜(plan_type)을 계정 대용으로 씁니다. 같은 플랜을 쓰는 계정이 둘 이상이면 구분되지 않습니다. 아래 토큰 집계는 계정 구분 없이 전부 합산한 값입니다.")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private func gauge(_ title: String, _ w: CodexRateWindow?, _ base: Color) -> some View {
        let p = (w?.usedPercent ?? 0) / 100
        let color = w == nil ? Theme.faint : (p > 0.85 ? Theme.red : (p > 0.6 ? Theme.orange : base))
        let now = Int32(Date().timeIntervalSince1970)
        return VStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            ZStack {
                Circle().stroke(Theme.cardAlt, lineWidth: 12)
                Circle().trim(from: 0, to: min(1, p))
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(w == nil ? "–" : "\(Int(w!.usedPercent))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text(w == nil ? "" : "남은 \(Int(100 - w!.usedPercent))%")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            }
            .frame(width: 108, height: 108)
            if let w, let r = w.resetsAt {
                VStack(spacing: 2) {
                    Text("리셋 \(TimeUtil.resetLabel(r))")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Text(r > now ? TimeUtil.duration(seconds: Int(r) - Int(now)) + " 남음" : "지남")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 최근 7일 실제 사용량 (로컬 로그 기준) — 공식 %와 나란히 보기 위한 참고값.
    private var recentStrip: some View {
        let week = view.totals(fromDay: today - 6, toDay: today)
        return VStack(alignment: .leading, spacing: 9) {
            Text("최근 7일 (로컬 로그)").font(.system(size: 12)).foregroundStyle(Theme.dim)
            row("총 처리", Fmt.tokens(week.total))
            row("출력", Fmt.tokens(week.output))
            row("실제 새 입력", Fmt.tokens(week.freshInput))
            row("캐시 적중", week.input > 0
                ? String(format: "%.1f%%", Double(week.cached) / Double(week.input) * 100) : "-")
            row("요청", Fmt.decimal(Int64(week.events)))
        }
        .frame(width: 240, alignment: .leading)
    }

    /// 다른 플랜(=다른 계정)의 마지막 관측. 계정을 오갈 때 뭘 놓치고 있는지 보이게 한다.
    private var otherPlans: some View {
        let mine = snap.account.planType
        let others = snap.rateLimitsByPlan
            .filter { $0.key != mine }
            .sorted { $0.value.observedAt > $1.value.observedAt }
        return Group {
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("다른 플랜(계정)의 마지막 기록")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim)
                    ForEach(others, id: \.key) { plan, r in
                        HStack(spacing: 10) {
                            Text(plan).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.text).frame(width: 62, alignment: .leading)
                            Text("5시간 " + (r.fiveHour.map { "\(Int($0.usedPercent))%" } ?? "-"))
                                .font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 82, alignment: .leading)
                            Text("7일 " + (r.weekly.map { "\(Int($0.usedPercent))%" } ?? "-"))
                                .font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 72, alignment: .leading)
                            Text(r.age).font(.system(size: 11)).foregroundStyle(Theme.faint)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).font(.system(size: 12)).foregroundStyle(Theme.dim)
            Spacer()
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
        }
    }

    // MARK: KPI

    private var kpiRow: some View {
        let g = view.grand
        let hit = g.input > 0 ? Double(g.cached) / Double(g.input) : 0
        return HStack(spacing: 12) {
            StatTile(label: "전체 기간 (총 처리)", value: Fmt.tokens(g.total),
                     caption: "\(view.dailySeries().count)일 활동 · \(Fmt.decimal(Int64(g.events)))건 · 추정 \(Fmt.usd(CodexCost.totalCost(snap, plan: plan)))")
            StatTile(label: "오늘", value: Fmt.tokens(todayT.total),
                     caption: "출력 \(Fmt.tokens(todayT.output)) · 추정 \(Fmt.usd(CodexCost.rangeCost(snap, plan: plan, from: today, to: today)))")
            StatTile(label: "이번 달", value: Fmt.tokens(monthT.total),
                     caption: "출력 \(Fmt.tokens(monthT.output)) · 추정 \(Fmt.usd(CodexCost.rangeCost(snap, plan: plan, from: TimeUtil.startOfMonthDay(), to: today)))")
            StatTile(label: "실제 새 입력", value: Fmt.tokens(g.freshInput),
                     caption: "캐시 제외 · 전체 기간", valueColor: Theme.blue)
            StatTile(label: "캐시 적중률", value: String(format: "%.1f%%", hit * 100),
                     caption: "input 중 캐시 읽기 비중", valueColor: Theme.green)
        }
    }

    // MARK: 모델 / 프로젝트

    private var modelCard: some View {
        let models = view.rankedModels(snap.models).filter { CodexCost.isKnown($0.name) }
        let costs = CodexCost.costByModelName(snap, plan: plan)
        let total = max(1, view.grand.total)
        let unk = CodexCost.unknownShare(snap, plan: plan)
        let unpriced = CodexCost.unpricedShare(snap, plan: plan)
        return CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "모델별", trailing: "\(models.count)종 · 추정 \(Fmt.usd(costs.values.reduce(0, +)))")
                Chart(Array(models.enumerated()), id: \.offset) { idx, m in
                    SectorMark(angle: .value("토큰", m.totals.total),
                               innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(by: .value("모델", m.name))
                }
                .chartForegroundStyleScale(
                    domain: models.map(\.name),
                    range: models.enumerated().map { i, _ in Theme.series[i % Theme.series.count] })
                .chartLegend(.hidden)
                .frame(height: 172)
                VStack(spacing: 6) {
                    ForEach(Array(models.enumerated()), id: \.offset) { idx, m in
                        HStack(spacing: 8) {
                            Circle().fill(Theme.series[idx % Theme.series.count]).frame(width: 8, height: 8)
                            Text(m.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer(minLength: 10)
                            Text(String(format: "%.1f%%", Double(m.totals.total) / Double(total) * 100))
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.faint)
                            Text(Fmt.tokens(m.totals.total))
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                                .frame(width: 66, alignment: .trailing)
                            Text(Fmt.usd(costs[m.name] ?? 0))
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                                .frame(width: 66, alignment: .trailing)
                        }
                    }
                }
                if unpriced > 0 {
                    Text("요율표 없음 \(String(format: "%.1f%%", unpriced * 100)) 제외(모델 미상 \(String(format: "%.1f%%", unk * 100)) 포함) · 비용은 공개 요율 추정치")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
        }
        .frame(width: 420)
    }

    private var projectCard: some View {
        let projects = view.rankedProjects(snap.projects)
        let costs = CodexCost.costByProjectPath(snap, plan: plan)
        let maxV = projects.first?.totals.total ?? 1
        let total = max(1, view.grand.total)
        return CardBox {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "프로젝트 (토큰 많은 순)", trailing: "\(projects.count)개")
                    .padding(.bottom, 12)
                HStack(spacing: 10) {
                    Text("#").frame(width: 22, alignment: .trailing)
                    Text("프로젝트").frame(maxWidth: .infinity, alignment: .leading)
                    Text("비중").frame(width: 120, alignment: .leading)
                    Text("출력").frame(width: 70, alignment: .trailing)
                    Text("총 처리").frame(width: 78, alignment: .trailing)
                    Text("비용(추정)").frame(width: 66, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                Divider().overlay(Theme.border).padding(.vertical, 6)
                ForEach(Array(projects.prefix(14).enumerated()), id: \.offset) { idx, p in
                    HStack(spacing: 10) {
                        Text("\(idx + 1)").font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.faint).frame(width: 22, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.text).lineLimit(1)
                            Text(p.path).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.cardAlt).frame(height: 6)
                                    Capsule().fill(Theme.series[idx % Theme.series.count])
                                        .frame(width: geo.size.width * Double(p.totals.total) / Double(maxV),
                                               height: 6)
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                            }
                            .frame(width: 74)
                            Text(String(format: "%.1f%%", Double(p.totals.total) / Double(total) * 100))
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.dim)
                                .frame(width: 38, alignment: .trailing)
                        }
                        .frame(width: 120)
                        Text(Fmt.tokens(p.totals.output))
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                            .frame(width: 70, alignment: .trailing)
                        Text(Fmt.tokens(p.totals.total))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.text).frame(width: 78, alignment: .trailing)
                        Text(Fmt.usd(costs[p.path] ?? 0))
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    if idx < min(14, projects.count) - 1 { Divider().overlay(Theme.border.opacity(0.45)) }
                }
            }
        }
    }

    // MARK: 일별

    private struct P: Identifiable { let id: Int32; let date: Date; let total: Int64; let output: Int64 }

    private var dailyCard: some View {
        let pts = view.dailySeries().map {
            P(id: $0.day, date: TimeUtil.startOfLocalDay($0.day),
              total: $0.totals.total, output: $0.totals.output)
        }
        let rangeCost = pts.isEmpty ? 0 : CodexCost.rangeCost(
            snap, plan: plan, from: pts.first!.id, to: pts.last!.id)
        return CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "일별 사용량",
                             trailing: pts.isEmpty ? "" :
                                "\(TimeUtil.dayString(pts.first!.id)) → \(TimeUtil.dayString(pts.last!.id)) · 추정 \(Fmt.usd(rangeCost))")
                Chart(pts) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day), y: .value("토큰", p.total))
                        .foregroundStyle(.linearGradient(
                            colors: [Theme.teal, Theme.teal.opacity(0.4)],
                            startPoint: .top, endPoint: .bottom))
                }
                .chartYAxis { tokenAxis() }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 210)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("파일 \(Fmt.decimal(Int64(snap.scannedFiles)))개 · 이벤트 \(Fmt.decimal(Int64(view.grand.events)))건 · 스캔 \(String(format: "%.1f", snap.scanSeconds))초 · ~/.codex/sessions")
            Text("Codex 는 total_token_usage 가 세션 누계라 증가분만 더합니다(중복 이벤트는 증가분 0으로 자동 배제). 필드가 포함관계라 total = input + output 이고 캐시 읽기는 input 의 일부입니다 — Claude 처럼 캐시를 따로 더하면 이중 계상됩니다.")
            Text("resume 때문에 파일명 날짜와 내용 날짜가 다를 수 있어, 귀속은 각 이벤트의 타임스탬프(KST)를 씁니다. 비용은 OpenAI 공개 요율(캐시 읽기 0.1x, 추론은 출력)로 계산한 추정치입니다. gpt-5.6-sol 은 2026-11-21까지 할인($4/$20), 이후 정가($5/$30)를 일자별로 적용합니다. 요율표에 없는 모델(미상 포함)은 0원 처리하고 순위에서 제외합니다.")
            Text("계정 구분은 로그의 plan_type 을 대용으로 씁니다(세션 로그에 계정 식별자가 없음). 같은 플랜을 쓰는 계정이 둘 이상이면 합쳐져 보이고, plan 이 한 번도 기록되지 않은 파일은 '미상'으로 잡힙니다.")
        }
        .font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.top, 2)
    }
}

/// 스캔 대기/부재 상태를 감싸는 래퍼.
struct CodexTabView: View {
    let snap: CodexSnapshot?

    var body: some View {
        if let snap, !snap.isEmpty {
            CodexView(snap: snap)
        } else {
            VStack(spacing: 12) {
                Spacer(minLength: 140)
                if CodexScanner.isAvailable {
                    ProgressView().progressViewStyle(.circular).tint(Theme.teal)
                    Text("Codex 세션 로그 스캔 중…")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                } else {
                    Text("~/.codex/sessions 를 찾지 못했습니다.")
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Text("Codex CLI 를 이 컴퓨터에서 사용하면 자동으로 집계됩니다.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
