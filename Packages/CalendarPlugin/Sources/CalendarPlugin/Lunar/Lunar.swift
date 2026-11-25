import Foundation

/// 农历、节气、节日。农历用系统自带的中国历法，节气用公式算，都不联网。
public nonisolated enum Lunar {
    static let chinese: Calendar = {
        var c = Calendar(identifier: .chinese)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    static let monthNames = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
    static let dayNames = [
        "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
        "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
        "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
    ]
    static let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
    static let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
    static let zodiacs = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]

    public struct LunarDate: Sendable, Equatable {
        public let month: Int
        public let day: Int
        public let isLeapMonth: Bool
        /// 农历年在 60 年周期里的序号（1 = 甲子）。
        public let cycleYear: Int

        public var monthName: String { (isLeapMonth ? "闰" : "") + Lunar.monthNames[month - 1] }
        public var dayName: String { Lunar.dayNames[day - 1] }
        /// "十月十七"
        public var text: String { monthName + dayName }
        /// "丙午年"
        public var ganzhiYear: String { Lunar.stems[(cycleYear - 1) % 10] + Lunar.branches[(cycleYear - 1) % 12] + "年" }
        /// "马"
        public var zodiac: String { Lunar.zodiacs[(cycleYear - 1) % 12] }
    }

    /// 公历日期对应的农历（按本地日期的正午算，避免时区跨日）。
    public static func lunar(_ date: Date) -> LunarDate {
        let noon = gregorian.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let c = chinese.dateComponents([.year, .month, .day], from: noon)
        return LunarDate(month: c.month ?? 1, day: c.day ?? 1, isLeapMonth: c.isLeapMonth ?? false, cycleYear: c.year ?? 1)
    }

    // MARK: 节气

    public static let solarTermNames = [
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至",
        "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    ]
    /// 每个节气相对小寒的分钟偏移（经典近似表），只用作牛顿迭代的初值。
    static let termMinutes: [Double] = [
        0, 21208, 42467, 63836, 85337, 107014, 128867, 150921, 173149, 195551, 218072, 240693,
        263343, 285989, 308563, 331033, 353350, 375494, 397447, 419210, 440795, 462224, 483532, 504758,
    ]

    /// 某年第 n 个节气（0 = 小寒）的北京时间日期（yyyy-MM-dd）。
    /// 按太阳视黄经到达 285° + 15°·n 的时刻计算（Meeus 低精度太阳位置，误差约十几分钟）。
    public static func solarTermDay(year: Int, index n: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: solarTermInstant(year: year, index: n))
    }

    /// 节气的精确时刻。
    public static func solarTermInstant(year: Int, index n: Int) -> Date {
        let target = (285 + 15 * Double(n)).truncatingRemainder(dividingBy: 360)
        // 初值：经典近似公式
        let ms = 31556925974.7 * Double(year - 1900) + termMinutes[n] * 60000 - 2208549300000.0
        var jd = ms / 86_400_000 + 2440587.5
        for _ in 0..<6 {
            var diff = target - sunLongitude(jd: jd)
            diff = (diff + 540).truncatingRemainder(dividingBy: 360) - 180
            jd += diff / 360 * 365.2422
            if abs(diff) < 1e-6 { break }
        }
        return Date(timeIntervalSince1970: (jd - 2440587.5) * 86400)
    }

    /// 太阳视黄经（度），Meeus《天文算法》第 25 章低精度公式。
    static func sunLongitude(jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525
        let rad = Double.pi / 180
        let l0 = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
        let m = (357.52911 + 35999.05029 * t - 0.0001537 * t * t) * rad
        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(m)
            + (0.019993 - 0.000101 * t) * sin(2 * m) + 0.000289 * sin(3 * m)
        let omega = (125.04 - 1934.136 * t) * rad
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(omega)
        let r = lambda.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    private static let termCache = TermCache()

    /// 这一天是不是节气。
    public static func solarTerm(_ date: Date) -> String? {
        let year = gregorian.component(.year, from: date)
        return termCache.terms(year: year)[dayKey(date)]
    }

    // MARK: 节日

    static let solarFestivals: [String: String] = [
        "01-01": "元旦", "02-14": "情人节", "03-08": "妇女节", "03-12": "植树节", "04-01": "愚人节",
        "05-01": "劳动节", "05-04": "青年节", "06-01": "儿童节", "07-01": "建党节", "08-01": "建军节",
        "09-10": "教师节", "10-01": "国庆节", "10-31": "万圣夜", "11-01": "万圣节", "11-08": "记者节",
        "11-17": "学生日", "12-24": "平安夜", "12-25": "圣诞节",
    ]
    static let lunarFestivals: [String: String] = [
        "1-1": "春节", "1-15": "元宵节", "2-2": "龙抬头", "5-5": "端午节", "7-7": "七夕",
        "7-15": "中元节", "8-15": "中秋节", "9-9": "重阳节", "10-1": "寒衣节", "10-15": "下元节",
        "12-8": "腊八节", "12-23": "小年",
    ]

    /// 节日（公历 / 农历 / 按星期算的），优先级：农历 > 公历 > 星期节日。
    public static func festival(_ date: Date) -> String? {
        let l = lunar(date)
        if !l.isLeapMonth {
            if let f = lunarFestivals["\(l.month)-\(l.day)"] { return f }
            // 除夕：明天是正月初一。
            if l.month == 12, let tomorrow = gregorian.date(byAdding: .day, value: 1, to: date) {
                let t = lunar(tomorrow)
                if t.month == 1, t.day == 1, !t.isLeapMonth { return "除夕" }
            }
        }
        let c = gregorian.dateComponents([.month, .day, .weekday, .weekdayOrdinal], from: date)
        if let f = solarFestivals[String(format: "%02d-%02d", c.month ?? 0, c.day ?? 0)] { return f }
        // 母亲节：5 月第 2 个周日；父亲节：6 月第 3 个周日；感恩节：11 月第 4 个周四。
        switch (c.month, c.weekday, c.weekdayOrdinal) {
        case (5, 1, 2): return "母亲节"
        case (6, 1, 3): return "父亲节"
        case (11, 5, 4): return "感恩节"
        default: return nil
        }
    }

    /// 月历格子下面那行字：节日 > 节气 > 农历日（和百度一致，初一也显示"初一"）。
    public static func cellLabel(_ date: Date) -> (text: String, isSpecial: Bool) {
        if let f = festival(date) { return (f, true) }
        if let t = solarTerm(date) { return (t, true) }
        return (lunar(date).dayName, false)
    }

    static func dayKey(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

private nonisolated final class TermCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byYear: [Int: [String: String]] = [:]

    func terms(year: Int) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let t = byYear[year] { return t }
        var t: [String: String] = [:]
        for i in 0..<24 { t[Lunar.solarTermDay(year: year, index: i)] = Lunar.solarTermNames[i] }
        byYear[year] = t
        return t
    }
}
