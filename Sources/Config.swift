import Foundation

/// 앱이 보여주는 실제 사용률(%)을 기준점으로 삼아 한도를 역산한다.
/// Anthropic 이 한도 토큰 수를 공개하지 않으므로: `한도 = (그 시점 사용량) ÷ (앱 표시 %)`.
/// 기준점을 한 번 고정해 두면, 이후엔 `현재 사용량 / 역산한 한도` 로 남은 여유를 계속 보여줄 수 있다.
struct Calibration: Codable {
    var at: Int32                // 기준 시각 (epoch 초)
    var weeklyPercent: Double?   // 그 시각 앱의 "7일 사용률" (0~1)
    var fiveHourPercent: Double? // 그 시각 앱의 "5시간 사용률"
    var fablePercent: Double?    // 앱에 Fable/Opus 전용 주간 %가 있으면
}

struct Config: Codable {
    var plan: String = "Max 20x"

    // 주간 한도 리셋 기준 (이미지: 매주 목요일 18:00). weekday 0=일 … 6=토.
    var weeklyResetWeekday: Int = 4
    var weeklyResetHour: Int = 18

    // 한도를 직접 아는 경우 원시 토큰 수로 지정 (nil 이면 calibration 으로 역산).
    var limitFiveHour: Int64?
    var limitWeeklyAll: Int64?
    var limitWeeklyFable: Int64?

    var calibration: Calibration?

    /// 다른 컴퓨터의 ~/.claude/projects 사본 경로들. 기본 루트와 병합 집계된다.
    /// 예: ["~/claude-logs-macbook"]  (rsync/AirDrop 으로 통째 복사해 두면 됨)
    /// 같은 요청이 양쪽에 있어도 (message.id+requestId) 중복 제거로 이중 계상되지 않는다.
    var extraRoots: [String]?

    // MARK: 저장/불러오기

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage/config.json")
    }

    /// 보내주신 이미지(2026-07-23 ~11:54, 5시간 12% / 7일 87%) 기준으로 씨앗값을 잡는다.
    static var seeded: Config {
        var c = Config()
        let at = TimeUtil.epoch(2026, 7, 23, 11, 54)
        c.calibration = Calibration(at: at, weeklyPercent: 0.87, fiveHourPercent: 0.12, fablePercent: nil)
        return c
    }

    static func load() -> Config {
        let url = fileURL
        if let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        let c = seeded
        c.save()
        return c
    }

    func save() {
        let url = Config.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: url) }
    }
}

/// 역산 결과. 0 이면 "미설정"(보정값이 없어 한도 대비 표시 불가).
struct DerivedLimits {
    var fiveHour: Int64 = 0
    var weeklyAll: Int64 = 0
    var weeklyFable: Int64 = 0
    var calibrated = false
}
