import Foundation

/// 统一的中文日期格式，不跟随系统语言（系统是英文时也显示"11月25日 周三"）。
public nonisolated enum CN {
    public static let locale = Locale(identifier: "zh_CN")

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    private static func components(_ d: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: d)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// 11月25日
    public static func monthDay(_ d: Date) -> String {
        let c = components(d)
        return "\(c.month ?? 1)月\(c.day ?? 1)日"
    }

    /// 11/25
    public static func slash(_ d: Date) -> String {
        let c = components(d)
        return "\(c.month ?? 1)/\(c.day ?? 1)"
    }

    /// 周三
    public static func weekdayShort(_ d: Date) -> String {
        let idx = max(0, min(6, (components(d).weekday ?? 1) - 1))
        return "周\(weekdays[idx])"
    }

    /// 星期三
    public static func weekday(_ d: Date) -> String {
        let idx = max(0, min(6, (components(d).weekday ?? 1) - 1))
        return "星期\(weekdays[idx])"
    }

    /// 12:25（24 小时制）
    public static func time(_ d: Date) -> String {
        let c = components(d)
        return "\(twoDigits(c.hour ?? 0)):\(twoDigits(c.minute ?? 0))"
    }

    /// 2026年11月25日 星期三
    public static func full(_ d: Date) -> String {
        let c = components(d)
        let idx = max(0, min(6, (c.weekday ?? 1) - 1))
        return "\(c.year ?? 1970)年\(c.month ?? 1)月\(c.day ?? 1)日 星期\(weekdays[idx])"
    }

    /// 11月25日 12:25
    public static func dateTime(_ d: Date) -> String {
        let c = components(d)
        return "\(c.month ?? 1)月\(c.day ?? 1)日 \(twoDigits(c.hour ?? 0)):\(twoDigits(c.minute ?? 0))"
    }
}
