import EventKit
import Foundation
import Observation

/// 会议日程来源。
public nonisolated enum MeetingSource: String, Codable, Sendable, Equatable {
    case systemCalendar
    case dingtalk

    public var displayName: String {
        switch self {
        case .systemCalendar: "系统日历"
        case .dingtalk: "钉钉日程"
        }
    }
}

/// 会议日程同步相关设置键（主工作台与独立版万年历共享）。
public nonisolated enum MeetingKeys {
    public static let systemCalendarEnabled = SettingKey<Bool>("calendar.events.systemEnabled", default: false)
    public static let dingtalkCalendarEnabled = SettingKey<Bool>("calendar.events.dingtalkEnabled", default: false)
    public static let hideAllDayEvents = SettingKey<Bool>("calendar.events.hideAllDay", default: true)
}

/// 单条会议或日程记录。
public nonisolated struct MeetingEvent: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let calendarTitle: String
    public let location: String?
    public let meetingURL: URL?
    public let source: MeetingSource

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarTitle: String = "",
        location: String? = nil,
        meetingURL: URL? = nil,
        source: MeetingSource = .systemCalendar
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.location = location
        self.meetingURL = meetingURL
        self.source = source
    }

    public var durationMinutes: Int {
        max(0, Int(endDate.timeIntervalSince(startDate) / 60))
    }

    /// 转为禅道日报草稿时的建议工时（按 0.5h 对齐，范围 0.5 ~ 8.0）。
    public var suggestedLogHours: Double {
        if isAllDay { return 1.0 }
        let raw = max(0, endDate.timeIntervalSince(startDate) / 3600.0)
        let rounded = (raw * 2).rounded() / 2
        return min(8.0, max(0.5, rounded))
    }

    public func isOngoing(at now: Date) -> Bool {
        !isAllDay && startDate <= now && endDate > now
    }

    public func minutesUntilStart(from now: Date) -> Int {
        Int(ceil(startDate.timeIntervalSince(now) / 60.0))
    }

    /// 从会议地点、备注或在线链接文本中提取入会 URL（优先识别常见视频会议域名）。
    public static func extractMeetingURL(from texts: [String?]) -> URL? {
        let preferredHosts = [
            "feishu", "larksuite", "dingtalk", "tencent", "wemeet",
            "meeting", "zoom", "teams.microsoft", "meet.google", "webex",
        ]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        var candidates: [URL] = []
        for raw in texts {
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url,
                      let scheme = url.scheme?.lowercased(),
                      ["https", "http", "feishu", "dingtalk", "zoommtg", "wemeet"].contains(scheme) else {
                    continue
                }
                candidates.append(url)
            }
        }
        if let preferred = candidates.first(where: { url in
            let lower = url.absoluteString.lowercased()
            return preferredHosts.contains { lower.contains($0) }
        }) {
            return preferred
        }
        return candidates.first
    }

    /// 去重并排序：同分钟开始且同标题的跨源会议合并，优先保留含入会链接的条目。
    public static func deduplicateAndSort(_ events: [MeetingEvent], hideAllDay: Bool) -> [MeetingEvent] {
        var bestByKey: [String: MeetingEvent] = [:]
        var orderedKeys: [String] = []
        for event in events {
            if hideAllDay && event.isAllDay { continue }
            let cleanTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let startMinute = Int(event.startDate.timeIntervalSince1970 / 60)
            let key = "\(cleanTitle)|\(startMinute)|\(event.isAllDay ? 1 : 0)"
            if let existing = bestByKey[key] {
                if existing.meetingURL == nil, event.meetingURL != nil {
                    bestByKey[key] = event
                }
            } else {
                bestByKey[key] = event
                orderedKeys.append(key)
            }
        }
        return orderedKeys.compactMap { bestByKey[$0] }.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay && !rhs.isAllDay }
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// 解析 `dws calendar` JSON 输出为统一的 `MeetingEvent` 列表。
    public static func parseDingTalkEventsJSON(_ data: Data) -> [MeetingEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let dict = root as? [String: Any] {
            if let arr = dict["events"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["items"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["result"] as? [[String: Any]] {
                items = arr
            } else if let nested = dict["result"] as? [String: Any], let arr = nested["events"] as? [[String: Any]] {
                items = arr
            } else if let arr = dict["data"] as? [[String: Any]] {
                items = arr
            } else if let nested = dict["data"] as? [String: Any], let arr = nested["events"] as? [[String: Any]] {
                items = arr
            } else {
                items = []
            }
        } else {
            items = []
        }

        return items.compactMap { item in
            let title = (item["summary"] as? String)
                ?? (item["title"] as? String)
                ?? ""
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return nil }

            let isAllDay = (item["isAllDay"] as? Bool) ?? false
            guard let startDate = parseFlexibleDate(item["start"] ?? item["startTime"] ?? item["beginTime"]),
                  let endDate = parseFlexibleDate(item["end"] ?? item["endTime"] ?? item["finishTime"]) else {
                return nil
            }
            let safeEnd = max(endDate, startDate)

            let location: String? = {
                if let str = item["location"] as? String, !str.isEmpty { return str }
                if let locObj = item["location"] as? [String: Any] {
                    return (locObj["displayName"] as? String) ?? (locObj["name"] as? String)
                }
                return nil
            }()

            let onlineDict = (item["onlineMeetingInfo"] as? [String: Any])
                ?? (item["meetingInfo"] as? [String: Any])
            let urlCandidates: [String?] = [
                onlineDict?["url"] as? String,
                item["meetingUrl"] as? String,
                item["meetingURL"] as? String,
                location,
                item["description"] as? String,
            ]
            let meetingURL = extractMeetingURL(from: urlCandidates)
            let rawID = (item["id"] as? String)
                ?? (item["eventId"] as? String)
                ?? "\(cleanTitle)-\(Int(startDate.timeIntervalSince1970))"

            return MeetingEvent(
                id: "dingtalk.\(rawID)",
                title: cleanTitle,
                startDate: startDate,
                endDate: safeEnd,
                isAllDay: isAllDay,
                calendarTitle: "钉钉",
                location: location,
                meetingURL: meetingURL,
                source: .dingtalk
            )
        }
    }

    private static func parseFlexibleDate(_ value: Any?) -> Date? {
        if let dict = value as? [String: Any] {
            return parseFlexibleDate(dict["dateTime"] ?? dict["date"] ?? dict["timestamp"])
        }
        if let ts = value as? TimeInterval {
            return Date(timeIntervalSince1970: ts > 10_000_000_000 ? ts / 1000.0 : ts)
        }
        if let ts = value as? Int {
            let d = Double(ts)
            return Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000.0 : d)
        }
        guard let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty else {
            return nil
        }
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: str) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }

        let dayFmt = DateFormatter()
        dayFmt.calendar = Calendar(identifier: .gregorian)
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        if let d = dayFmt.date(from: str) { return d }

        let dtFmt = DateFormatter()
        dtFmt.calendar = Calendar(identifier: .gregorian)
        dtFmt.locale = Locale(identifier: "en_US_POSIX")
        dtFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return dtFmt.date(from: str)
    }
}

/// 聚合系统日历（`EventKit`）与钉钉日程的服务。
@Observable
public final class MeetingScheduleService {
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let eventStore = EKEventStore()

    public private(set) var authorizationStatus: EKAuthorizationStatus
    public private(set) var eventsByDay: [String: [MeetingEvent]] = [:]
    public private(set) var isRefreshing = false
    public private(set) var lastError: String?

    public init(settings: SettingsStore) {
        self.settings = settings
        self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    public func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// 仅在用户主动开启开关或点击授权按钮时请求系统日历读取权限，绝不在后台静默弹窗。
    @discardableResult
    public func requestSystemCalendarAccess() async -> Bool {
        refreshAuthorizationStatus()
        if authorizationStatus == .fullAccess {
            return true
        }
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            refreshAuthorizationStatus()
            if granted {
                lastError = nil
                await refresh(around: Date())
            }
            return granted
        } catch {
            refreshAuthorizationStatus()
            lastError = "系统日历授权失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 拉取 `anchorDate` 所在月前后范围（约 52 天）的会议与日程。
    public func refresh(around anchorDate: Date) async {
        refreshAuthorizationStatus()
        let sysEnabled = settings[MeetingKeys.systemCalendarEnabled]
        let dtEnabled = settings[MeetingKeys.dingtalkCalendarEnabled]
        guard sysEnabled || dtEnabled else {
            eventsByDay = [:]
            lastError = nil
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchorDate)) ?? cal.startOfDay(for: anchorDate)
        let windowStart = cal.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let windowEnd = cal.date(byAdding: .day, value: 45, to: monthStart) ?? monthStart

        var collected: [MeetingEvent] = []
        var warnings: [String] = []

        if sysEnabled {
            if authorizationStatus == .fullAccess {
                let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
                let ekEvents = eventStore.events(matching: predicate)
                for ev in ekEvents {
                    let title = (ev.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, let start = ev.startDate, let end = ev.endDate else { continue }
                    let url = ev.url ?? MeetingEvent.extractMeetingURL(from: [ev.location, ev.notes])
                    let id = ev.eventIdentifier ?? "\(title)-\(Int(start.timeIntervalSince1970))"
                    collected.append(MeetingEvent(
                        id: "sys.\(id).\(Int(start.timeIntervalSince1970))",
                        title: title,
                        startDate: start,
                        endDate: max(start, end),
                        isAllDay: ev.isAllDay,
                        calendarTitle: ev.calendar?.title ?? "日历",
                        location: ev.location,
                        meetingURL: url,
                        source: .systemCalendar
                    ))
                }
            } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                warnings.append("未获得系统日历完全访问权限，请在系统设置中授权。")
            }
        }

        if dtEnabled {
            let configuredPath = settings[WorkCalendar.dingtalkPathKey].trimmingCharacters(in: .whitespacesAndNewlines)
            let dwsPath: String?
            if !configuredPath.isEmpty, FileManager.default.isExecutableFile(atPath: configuredPath) {
                dwsPath = configuredPath
            } else {
                dwsPath = await DingTalkAttendance.locateExecutable()
            }

            if let dwsPath {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                let startStr = iso.string(from: windowStart)
                let endStr = iso.string(from: windowEnd)
                do {
                    let res = try await Shell.run(
                        dwsPath,
                        ["calendar", "event", "list", "--start-time", startStr, "--end-time", endStr, "--format", "json"],
                        timeout: 15
                    )
                    if res.status == 0, let data = res.stdout.data(using: .utf8) {
                        collected.append(contentsOf: MeetingEvent.parseDingTalkEventsJSON(data))
                    } else {
                        let detail = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        warnings.append(detail.isEmpty ? "钉钉日程暂不可用（退出码 \(res.status)）" : "钉钉日程同步提示：\(detail.prefix(80))")
                    }
                } catch {
                    warnings.append("钉钉日程拉取失败：\(error.localizedDescription)")
                }
            } else {
                warnings.append("未检测到 dws 命令，无法拉取钉钉日程。")
            }
        }

        lastError = warnings.isEmpty ? nil : warnings.joined(separator: "；")
        let hideAllDay = settings[MeetingKeys.hideAllDayEvents]
        let normalized = MeetingEvent.deduplicateAndSort(collected, hideAllDay: hideAllDay)

        var bucket: [String: [MeetingEvent]] = [:]
        for event in normalized {
            let startDay = cal.startOfDay(for: event.startDate)
            let adjustedEnd = event.endDate > event.startDate ? event.endDate.addingTimeInterval(-1) : event.endDate
            let endDay = cal.startOfDay(for: adjustedEnd)
            var cursor = startDay
            var safety = 0
            while cursor <= endDay && safety < 31 {
                let key = WorkCalendar.dayString(cursor)
                bucket[key, default: []].append(event)
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                safety += 1
            }
        }
        eventsByDay = bucket
    }

    public func events(on date: Date) -> [MeetingEvent] {
        eventsByDay[WorkCalendar.dayString(date)] ?? []
    }

    /// 查找当前正在进行中或即将开始（`withinMinutes` 内）的会议。
    public func nextUpcomingMeeting(now: Date = Date(), withinMinutes: Int = 60) -> MeetingEvent? {
        let todayEvents = events(on: now).filter { !$0.isAllDay }
        if let ongoing = todayEvents.first(where: { $0.isOngoing(at: now) }) {
            return ongoing
        }
        return todayEvents
            .filter { $0.startDate > now && $0.minutesUntilStart(from: now) <= withinMinutes }
            .min { $0.startDate < $1.startDate }
    }
}
