import SwiftUI
import Charts

/// 프로젝트 / 모델 / 세션을 토큰 많은 순으로 보여주는 공용 순위표.
struct RankView: View {
    enum Kind { case project, model, session }

    let snap: Snapshot
    let kind: Kind

    private var rows: [NamedTotals] {
        switch kind {
        case .project: return snap.rankedProjects()
        case .model: return snap.rankedModels()
        case .session: return snap.rankedSessions(limit: 150)
        }
    }

    private var heading: String {
        switch kind {
        case .project: return "프로젝트 (토큰 많은 순)"
        case .model: return "모델 (토큰 많은 순)"
        case .session: return "세션 (토큰 많은 순)"
        }
    }

    private var caption: String {
        switch kind {
        case .project: return "\(snap.projects.count)개 프로젝트"
        case .model: return "\(snap.models.count)개 모델"
        case .session: return "상위 150개 / 전체 \(Fmt.decimal(Int64(snap.sessions.count)))개"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if kind == .model { ModelSplitCard(snap: snap) }
            CardBox {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(text: heading, trailing: caption)
                        .padding(.bottom, 14)
                    header
                    Divider().overlay(Theme.border).padding(.vertical, 6)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        RankRow(rank: idx + 1, row: row, max: rows.first?.totals.total ?? 1,
                                grandTotal: snap.grand.total,
                                accent: kind == .model
                                    ? Theme.color(model: row.name)
                                    : Theme.series[idx % Theme.series.count])
                        if idx < rows.count - 1 {
                            Divider().overlay(Theme.border.opacity(0.45))
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 26, alignment: .trailing)
            Text(kind == .session ? "세션" : (kind == .model ? "모델" : "프로젝트"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("비중").frame(width: 150, alignment: .leading)
            Text("요청").frame(width: 62, alignment: .trailing)
            Text("출력").frame(width: 78, alignment: .trailing)
            Text("토큰").frame(width: 84, alignment: .trailing)
            Text("비용").frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.faint)
    }
}

private struct RankRow: View {
    let rank: Int
    let row: NamedTotals
    let max: Int64
    let grandTotal: Int64
    let accent: Color

    var body: some View {
        let share = grandTotal > 0 ? Double(row.totals.total) / Double(grandTotal) : 0
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.faint)
                .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.cardAlt).frame(height: 6)
                        Capsule().fill(accent)
                            .frame(width: geo.size.width * (max > 0 ? Double(row.totals.total) / Double(max) : 0),
                                   height: 6)
                    }
                    .frame(height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(width: 100)
                Text(String(format: "%.1f%%", share * 100))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 42, alignment: .trailing)
            }
            .frame(width: 150)

            Text(Fmt.decimal(Int64(row.totals.requests)))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                .frame(width: 62, alignment: .trailing)
            Text(Fmt.tokens(row.totals.output))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.dim)
                .frame(width: 78, alignment: .trailing)
            Text(Fmt.tokens(row.totals.total))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
                .frame(width: 84, alignment: .trailing)
            Text(Fmt.usd(row.totals.cost))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.green)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

/// 모델 탭 상단의 도넛 + 토큰 종류별 구성.
private struct ModelSplitCard: View {
    let snap: Snapshot

    var body: some View {
        let models = snap.rankedModels()
        return HStack(spacing: 18) {
            CardBox {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: "모델 구성", trailing: Fmt.tokens(snap.grand.total))
                    Chart(models) { m in
                        SectorMark(angle: .value("토큰", m.totals.total),
                                   innerRadius: .ratio(0.62),
                                   angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(by: .value("모델", m.name))
                    }
                    .chartForegroundStyleScale(domain: models.map(\.name),
                                               range: models.map { Theme.color(model: $0.name) })
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                    .frame(height: 250)
                }
            }
            .frame(width: 420)

            CardBox {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: "모델별 토큰 종류 구성", trailing: "캐시 읽기 비중이 대부분")
                    Chart {
                        ForEach(models.prefix(6)) { m in
                            let parts: [(String, Int64, Color)] = [
                                ("입력", m.totals.input, Theme.blue),
                                ("캐시 쓰기 5분", m.totals.cacheWrite5m, Theme.teal),
                                ("캐시 쓰기 1시간", m.totals.cacheWrite1h, Theme.purple),
                                ("캐시 읽기", m.totals.cacheRead, Theme.green),
                                ("출력", m.totals.output, Theme.orange),
                            ]
                            ForEach(parts, id: \.0) { part in
                                BarMark(x: .value("토큰", part.1),
                                        y: .value("모델", Fmt.modelShort(m.name)))
                                    .foregroundStyle(by: .value("종류", part.0))
                            }
                        }
                    }
                    .chartForegroundStyleScale(
                        domain: ["입력", "캐시 쓰기 5분", "캐시 쓰기 1시간", "캐시 읽기", "출력"],
                        range: [Theme.blue, Theme.teal, Theme.purple, Theme.green, Theme.orange])
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text(Fmt.axis(Int64(v))).foregroundStyle(Theme.dim)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel().foregroundStyle(Theme.dim)
                        }
                    }
                    .frame(height: 250)
                }
            }
        }
    }
}
