import SwiftUI
import Charts

struct DailyView: View {
    let snap: Snapshot

    private struct P: Identifiable { let id: Int32; let date: Date; let totals: Totals }

    private var series: [P] {
        snap.dailySeries().map { P(id: $0.day, date: TimeUtil.startOfLocalDay($0.day), totals: $0.totals) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            chartCard
            table
        }
    }

    private var chartCard: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "일별 토큰 사용량 (전체 기간)",
                             trailing: series.isEmpty ? "" :
                                "\(TimeUtil.dayString(series.first!.id)) → \(TimeUtil.dayString(series.last!.id))")
                Chart(series) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day),
                            y: .value("토큰", p.totals.total))
                        .foregroundStyle(.linearGradient(
                            colors: [Theme.green, Theme.green.opacity(0.45)],
                            startPoint: .top, endPoint: .bottom))
                    if let peak, p.id == peak.id {
                        RuleMark(y: .value("최고", p.totals.total))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Theme.orange.opacity(0.7))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("최고 \(Fmt.tokens(p.totals.total)) · \(TimeUtil.dayString(p.id))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.orange)
                            }
                    }
                }
                .chartYAxis { tokenAxis() }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(height: 280)
            }
        }
    }

    private var peak: P? { series.max { $0.totals.total < $1.totals.total } }

    private var table: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "일자별 상세", trailing: "최근 순 · \(series.count)일")
                    .padding(.bottom, 14)
                HStack(spacing: 12) {
                    Text("날짜").frame(width: 110, alignment: .leading)
                    Text("").frame(maxWidth: .infinity)
                    Text("요청").frame(width: 62, alignment: .trailing)
                    Text("입력").frame(width: 76, alignment: .trailing)
                    Text("캐시 쓰기").frame(width: 84, alignment: .trailing)
                    Text("캐시 읽기").frame(width: 84, alignment: .trailing)
                    Text("출력").frame(width: 76, alignment: .trailing)
                    Text("합계").frame(width: 84, alignment: .trailing)
                    Text("비용").frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.faint)
                Divider().overlay(Theme.border).padding(.vertical, 6)

                let maxTotal = series.map(\.totals.total).max() ?? 1
                ForEach(series.reversed()) { p in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(TimeUtil.dayString(p.id))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.text)
                            Text(TimeUtil.shortDayString(p.id))
                                .font(.system(size: 10)).foregroundStyle(Theme.faint)
                        }
                        .frame(width: 110, alignment: .leading)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.cardAlt).frame(height: 6)
                                Capsule().fill(Theme.green.opacity(0.85))
                                    .frame(width: geo.size.width * Double(p.totals.total) / Double(maxTotal),
                                           height: 6)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(maxWidth: .infinity)

                        num(Fmt.decimal(Int64(p.totals.requests)), 62)
                        num(Fmt.tokens(p.totals.input), 76)
                        num(Fmt.tokens(p.totals.cacheWrite5m + p.totals.cacheWrite1h), 84)
                        num(Fmt.tokens(p.totals.cacheRead), 84)
                        num(Fmt.tokens(p.totals.output), 76)
                        Text(Fmt.tokens(p.totals.total))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.text)
                            .frame(width: 84, alignment: .trailing)
                        Text(Fmt.usd(p.totals.cost))
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Theme.green)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    Divider().overlay(Theme.border.opacity(0.4))
                }
            }
        }
    }

    private func num(_ s: String, _ w: CGFloat) -> some View {
        Text(s)
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(Theme.dim)
            .frame(width: w, alignment: .trailing)
    }
}
