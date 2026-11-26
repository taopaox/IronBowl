import Foundation

/// 剩余时间文字，比如 "1:05"、"23分"。
public func countdown(to date: Date, from now: Date = Date()) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)分"
}

/// 剩余时长文字，比如 "8小时25分"、"8小时"、"23分钟"、"不到1分钟"。
public nonisolated func remainingTimeText(to date: Date, from now: Date = Date()) -> String {
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "0分钟" }
    if seconds < 60 { return "不到1分钟" }
    let totalMinutes = Int(seconds / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 { return "\(hours)小时\(minutes)分" }
    if hours > 0 { return "\(hours)小时" }
    return "\(minutes)分钟"
}
