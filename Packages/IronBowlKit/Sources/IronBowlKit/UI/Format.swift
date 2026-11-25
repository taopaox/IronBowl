import Foundation

/// 剩余时间文字，比如 "1:05"、"23分"。
public func countdown(to date: Date, from now: Date = Date()) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)分"
}
