import Foundation

/// 紧凑剩余时长文字，比如 "5小时44分"、"2小时"、"23分"、"不到1分"。
public nonisolated func countdown(to date: Date, from now: Date = Date()) -> String {
    formatDuration(to: date, from: now, minuteUnit: "分")
}

/// 剩余时长文字，比如 "8小时25分"、"8小时"、"23分钟"、"不到1分钟"。
public nonisolated func remainingTimeText(to date: Date, from now: Date = Date()) -> String {
    formatDuration(to: date, from: now, minuteUnit: "分钟")
}

private nonisolated func formatDuration(to date: Date, from now: Date, minuteUnit: String) -> String {
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "0\(minuteUnit)" }
    if seconds < 60 { return "不到1\(minuteUnit)" }
    let totalMinutes = Int(seconds / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 { return "\(hours)小时\(minutes)分" }
    if hours > 0 { return "\(hours)小时" }
    return "\(minutes)\(minuteUnit)"
}
