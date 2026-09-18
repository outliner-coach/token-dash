import SwiftUI

enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let card = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let cardAlt = Color(red: 0.106, green: 0.106, blue: 0.118)
    static let border = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let text = Color(red: 0.949, green: 0.949, blue: 0.969)
    static let dim = Color(red: 0.557, green: 0.557, blue: 0.576)
    static let faint = Color(red: 0.38, green: 0.38, blue: 0.41)

    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let blue = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.624, blue: 0.039)
    static let purple = Color(red: 0.749, green: 0.353, blue: 0.949)
    static let red = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let teal = Color(red: 0.392, green: 0.824, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.392, blue: 0.510)
    static let yellow = Color(red: 1.0, green: 0.839, blue: 0.039)

    /// 모델별 고정 색. 참고 이미지와 같은 계열 (opus=green, fable=blue, sonnet=orange).
    static func color(model: String) -> Color {
        if model.hasPrefix("claude-opus-4-8") { return green }
        if model.hasPrefix("claude-opus-4-7") { return teal }
        if model.hasPrefix("claude-opus-4-6") { return Color(red: 0.24, green: 0.62, blue: 0.45) }
        if model.hasPrefix("claude-opus") { return Color(red: 0.36, green: 0.72, blue: 0.55) }
        if model.hasPrefix("claude-fable") || model.hasPrefix("claude-mythos") { return blue }
        if model.hasPrefix("claude-sonnet-5") { return orange }
        if model.hasPrefix("claude-sonnet") { return yellow }
        if model.hasPrefix("claude-haiku") { return purple }
        return faint
    }

    /// 순위표용 팔레트.
    static let series: [Color] = [green, blue, orange, purple, teal, pink, yellow, red]
}

/// 참고 이미지의 카드 스타일 (짙은 배경 + 얇은 테두리 + 큰 라운드).
struct CardBox<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// KPI 타일: 라벨 / 큰 숫자 / 보조 문구.
struct StatTile: View {
    let label: String
    let value: String
    let caption: String
    var valueColor: Color = Theme.text

    var body: some View {
        CardBox(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.dim)
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}
