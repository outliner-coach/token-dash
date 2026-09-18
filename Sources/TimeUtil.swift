import Foundation

/// DateFormatter 없이 고정 포맷 ISO8601 을 다루기 위한 헬퍼.
/// 세션 로그가 20만 줄 규모라 Foundation 파서를 쓰면 스캔이 수십 초로 늘어난다.
enum TimeUtil {
    /// 실행 시점의 로컬 UTC 오프셋 (초). 한국이면 32400.
    static let tzOffset: Int32 = Int32(TimeZone.current.secondsFromGMT())

    private static let dayNames = ["일", "월", "화", "수", "목", "금", "토"]

    /// Howard Hinnant, days_from_civil.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = y0 - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// days_from_civil 의 역함수.
    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }

    /// 로컬 기준 일자 번호 (1970-01-01 로컬 = 0).
    static func localDay(_ ts: Int32) -> Int32 {
        Int32(floorDiv(Int(ts) + Int(tzOffset), 86400))
    }

    static func startOfLocalDay(_ day: Int32) -> Date {
        Date(timeIntervalSince1970: Double(Int(day) * 86400 - Int(tzOffset)))
    }

    /// 로컬 시각(y-m-d h:mi)을 epoch 초로.
    static func epoch(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Int32 {
        Int32(daysFromCivil(y, m, d) * 86400 + h * 3600 + mi * 60 - Int(tzOffset))
    }

    /// 지정 요일·시각(로컬)을 시작점으로 하는 7일 창 중, `now` 를 포함하는 것.
    /// weekday: 0=일 … 6=토 (1970-01-01 = 목 = 4).
    static func weeklyWindow(weekday: Int, hour: Int, now: Int32) -> (start: Int32, end: Int32) {
        let local = Int(now) + Int(tzOffset)
        let curDay = floorDiv(local, 86400)
        let curDow = floorMod(curDay + 4, 7)
        let secOfDay = floorMod(local, 86400)
        var back = floorMod(curDow - weekday, 7)
        if back == 0 && secOfDay < hour * 3600 { back = 7 }   // 오늘이 그 요일이지만 아직 리셋 전
        var anchorLocal = (curDay - back) * 86400 + hour * 3600
        if anchorLocal > local { anchorLocal -= 7 * 86400 }
        let start = Int32(anchorLocal - Int(tzOffset))
        return (start, start + 7 * 24 * 3600)
    }

    /// "7/23(목) 오후 6시" 형태.
    static func resetLabel(_ ts: Int32) -> String {
        let local = Int(ts) + Int(tzOffset)
        let sod = floorMod(local, 86400)
        let h = sod / 3600
        let ampm = h < 12 ? "오전" : "오후"
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(shortDayString(localDay(ts))) \(ampm) \(h12)시"
    }

    /// 로컬 시각 기준으로 정시 내림.
    static func floorToLocalHour(_ ts: Int32) -> Int32 {
        let local = Int(ts) + Int(tzOffset)
        return Int32(local - floorMod(local, 3600) - Int(tzOffset))
    }

    static func dayString(_ day: Int32) -> String {
        let c = civilFromDays(Int(day))
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    static func shortDayString(_ day: Int32) -> String {
        let c = civilFromDays(Int(day))
        let dow = floorMod(Int(day) + 4, 7)   // 1970-01-01 은 목요일
        return String(format: "%d/%d (%@)", c.month, c.day, dayNames[dow])
    }

    static func clockString(_ ts: Int32) -> String {
        let local = Int(ts) + Int(tzOffset)
        let sod = floorMod(local, 86400)
        return String(format: "%02d:%02d", sod / 3600, (sod % 3600) / 60)
    }

    /// "3h 42m" 형태의 잔여 시간.
    static func duration(seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// "2026-07-15T03:28:34.052Z" 를 epoch 초로. 실패하면 0.
    static func parseISO(_ b: UnsafeRawBufferPointer, _ p: Int) -> Int32 {
        guard p + 19 <= b.count else { return 0 }
        @inline(__always) func d(_ i: Int) -> Int { Int(b[p + i]) - 48 }
        let year = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
        let month = d(5) * 10 + d(6)
        let day = d(8) * 10 + d(9)
        let hour = d(11) * 10 + d(12)
        let min = d(14) * 10 + d(15)
        let sec = d(17) * 10 + d(18)
        guard year > 1970, month >= 1, month <= 12, day >= 1, day <= 31 else { return 0 }
        let days = daysFromCivil(year, month, day)
        return Int32(days * 86400 + hour * 3600 + min * 60 + sec)
    }

    @inline(__always) static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    @inline(__always) static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return r < 0 ? r + b : r
    }

    // MARK: 오늘/이번 주/이번 달 경계 (로컬 달력 기준)

    static func todayDay() -> Int32 { localDay(Int32(Date().timeIntervalSince1970)) }

    static func startOfWeekDay() -> Int32 {
        let cal = Calendar.current
        let now = Date()
        guard let interval = cal.dateInterval(of: .weekOfYear, for: now) else { return todayDay() }
        return localDay(Int32(interval.start.timeIntervalSince1970))
    }

    static func startOfMonthDay() -> Int32 {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: Date())
        guard let start = cal.date(from: c) else { return todayDay() }
        return localDay(Int32(start.timeIntervalSince1970))
    }
}
