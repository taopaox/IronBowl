import Foundation

/// 统一的中文日期格式，不跟随系统语言（系统是英文时也显示"11月25日 周三"）。
public nonisolated enum CN {
    public static let locale = Locale(identifier: "zh_CN")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = format
        return f
    }

    private static let monthDayF = formatter("M月d日")
    private static let slashF = formatter("M/d")
    private static let weekdayShortF = formatter("EEE")   // 周三
    private static let weekdayF = formatter("EEEE")       // 星期三
    private static let timeF = formatter("HH:mm")
    private static let fullF = formatter("yyyy年M月d日 EEEE")
    private static let dateTimeF = formatter("M月d日 HH:mm")

    /// 11月25日
    public static func monthDay(_ d: Date) -> String { monthDayF.string(from: d) }
    /// 11/25
    public static func slash(_ d: Date) -> String { slashF.string(from: d) }
    /// 周三
    public static func weekdayShort(_ d: Date) -> String { weekdayShortF.string(from: d) }
    /// 星期三
    public static func weekday(_ d: Date) -> String { weekdayF.string(from: d) }
    /// 12:25（24 小时制）
    public static func time(_ d: Date) -> String { timeF.string(from: d) }
    /// 2026年11月25日 星期三
    public static func full(_ d: Date) -> String { fullF.string(from: d) }
    /// 11月25日 12:25
    public static func dateTime(_ d: Date) -> String { dateTimeF.string(from: d) }
}
