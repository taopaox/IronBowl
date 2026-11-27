import AppKit
import IronBowlKit
import SwiftUI

/// 万年历主页面：左边月历，右边当天详情 + 天气。
public struct CalendarMainView: View {
    let model: CalendarModel
    let versionText: String?
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    public init(model: CalendarModel, versionText: String? = nil) {
        self.model = model
        self.versionText = versionText
    }

    public var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("万年历", topPadding: 8) {
                HStack(spacing: 10) {
                    if let versionText, !versionText.isEmpty {
                        Text(versionText)
                            .font(DS.font(11.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.well, in: .capsule)
                    }
                    if versionText != nil || sidebarCollapsed {
                        Text("·")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textTertiary)
                        DSSloganView(style: .inline)
                    }
                }
            } actions: {
                if let w = model.weatherShort {
                    Label(w, systemImage: model.weather?.symbol ?? "cloud").font(DS.body).foregroundStyle(DS.textSecondary)
                }
            }
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    MonthCard(model: model, compact: false)
                    VStack(spacing: 14) {
                        DayDetailCard(model: model, compact: false)
                        WeatherCard(model: model)
                    }
                    .frame(width: DS.s(300))
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .background(DS.canvas)
    }
}

/// 紧凑版：菜单栏面板和独立版万年历用。
public struct CalendarCompactView: View {
    let model: CalendarModel

    public init(model: CalendarModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 10) {
            MonthCard(model: model, compact: true)
            DayDetailCard(model: model, compact: true)
        }
    }
}

// MARK: 月历卡

struct MonthCard: View {
    let model: CalendarModel
    let compact: Bool
    var bordered = true

    var body: some View {
        if bordered {
            DSCard(padding: compact ? 10 : 16) { grid }
        } else {
            grid.padding(12)
        }
    }

    private var grid: some View {
            VStack(spacing: compact ? 6 : 10) {
                header
                HStack(spacing: 0) {
                    ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, w in
                        Text(w.text)
                            .font(DS.font(compact ? 11.5 : 13))
                            .foregroundStyle(w.weekend ? DS.danger : DS.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, compact ? 2 : 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 4), count: 7), spacing: compact ? 2 : 4) {
                    let cal = CalendarModel.cal
                    let todayStart = cal.startOfDay(for: model.now)
                    let selectedStart = cal.startOfDay(for: model.selected)
                    ForEach(model.cells) { cell in
                        let cellStart = cal.startOfDay(for: cell.date)
                        DayCellView(
                            model: model,
                            cell: cell,
                            compact: compact,
                            isToday: cellStart == todayStart,
                            isSelected: cellStart == selectedStart
                        )
                    }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !compact {
                let holidays = model.workCalendar.holidays(inYear: model.year)
                DSPicker(
                    selection: Binding<Date?>(get: { nil }, set: { if let d = $0 { model.select(d) } }),
                    options: holidays.isEmpty
                        ? [DSPickerOption(nil, title: "暂无节假日数据", triggerTitle: "假期")]
                        : holidays.map { DSPickerOption(Date?.some($0.date), title: $0.name, subtitle: CN.monthDay($0.date)) },
                    placeholder: "假期"
                )
                Spacer()
            }
            DSPicker(selection: Binding(get: { model.year }, set: { model.go(year: $0) }),
                     options: (1990...2050).map { ($0, "\($0)年") })
            Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.dsGhost)
            DSPicker(selection: Binding(get: { model.monthNumber }, set: { model.go(month: $0) }),
                     options: (1...12).map { ($0, "\($0)月") })
            Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.dsGhost)
            Spacer()
            Button("今天") { model.goToday() }.buttonStyle(.dsSecondary)
        }
    }
}

struct DayCellView: View {
    let model: CalendarModel
    let cell: DayCell
    let compact: Bool
    let isToday: Bool
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let cal = CalendarModel.cal
        let info = model.workCalendar.dayInfo(cell.date)
        let weekday = cal.component(.weekday, from: cell.date)
        let red = info.kind == .holiday || ((weekday == 1 || weekday == 7) && info.kind != .makeupWorkday)
        let label = Lunar.cellLabel(cell.date)
        let badge = model.dayBadge(cell.date)
        let todoCounts = model.context.todos.counts(on: cell.date)
        let hasMeetings = !model.meetings.events(on: cell.date).isEmpty

        Button { model.select(cell.date) } label: {
            VStack(spacing: compact ? 0 : 2) {
                Text("\(cal.component(.day, from: cell.date))")
                    .font(DS.font(compact ? 15 : 19, isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(red ? DS.danger : DS.text)
                Text(label.text)
                    .font(DS.font(compact ? 9.5 : 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(label.isSpecial ? DS.danger : DS.textSecondary)
            }
            .opacity(cell.inMonth ? 1 : 0.35)
            .frame(maxWidth: .infinity)
            .frame(height: DS.s(compact ? 40 : 58))
            .background(statusBackground(info.kind, inMonth: cell.inMonth), in: .rect(cornerRadius: 8))
            .overlay {
                if isSelected || hovering {
                    RoundedRectangle(cornerRadius: 8).fill(DS.hover)
                }
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(DS.brand, lineWidth: 1.5)
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(DS.borderStrong, lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isToday {
                    Text("今").font(DS.font(9.5, .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(DS.brand, in: .rect(cornerRadius: 4))
                        .padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                if let badge {
                    let isHoliday = badge == "休"
                    Text(badge).font(DS.font(9.5, .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(isHoliday ? Self.holidayBadgeColor : Self.makeupBadgeColor, in: .rect(cornerRadius: 4))
                        .opacity(cell.inMonth ? 1 : 0.85)
                        .padding(3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                let hasTodos = todoCounts.incomplete + todoCounts.completed > 0
                if hasTodos || hasMeetings {
                    HStack(spacing: compact ? 2 : 3) {
                        if hasMeetings {
                            Circle()
                                .fill(DS.warning)
                                .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                        }
                        if hasTodos {
                            Circle()
                                .fill(todoCounts.incomplete > 0 ? DS.brand : DS.success)
                                .frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
                        }
                    }
                    .opacity(cell.inMonth ? 1 : 0.5)
                    .padding(compact ? 3 : 5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private static let holidayCellBg = Color(
        light: NSColor(srgbRed: 0.992, green: 0.925, blue: 0.933, alpha: 1),
        dark: NSColor(srgbRed: 0.898, green: 0.224, blue: 0.208, alpha: 0.22)
    )
    private static let makeupCellBg = Color(
        light: NSColor(srgbRed: 0.937, green: 0.937, blue: 0.949, alpha: 1),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    private static let holidayBadgeColor = Color(.sRGB, red: 0.898, green: 0.224, blue: 0.208, opacity: 1)
    private static let makeupBadgeColor = Color(.sRGB, red: 0.431, green: 0.455, blue: 0.502, opacity: 1)

    private func statusBackground(_ kind: DayInfo.Kind, inMonth: Bool) -> Color {
        switch kind {
        case .holiday: Self.holidayCellBg.opacity(inMonth ? 1 : 0.72)
        case .makeupWorkday: Self.makeupCellBg.opacity(inMonth ? 1 : 0.72)
        default: .clear
        }
    }
}

// MARK: 当天详情

struct DayDetailCard: View {
    let model: CalendarModel
    let compact: Bool
    @State private var newTodoTitle = ""
    @State private var loggedMeetingIDs: Set<String> = []

    var body: some View {
        let d = model.selected
        let l = Lunar.lunar(d)
        let info = model.workCalendar.dayInfo(d)
        let extra = [Lunar.festival(d), Lunar.solarTerm(d)].compactMap { $0 }
        let dayTodos = model.context.todos.items(on: d)
        let dayMeetings = model.meetings.events(on: d)
        let meetingsSyncEnabled = model.settings[MeetingKeys.systemCalendarEnabled] || model.settings[MeetingKeys.dingtalkCalendarEnabled]
        DSCard(padding: compact ? 12 : 16) {
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(l.text).font(DS.font(compact ? 17 : 22, .semibold))
                    Text("\(l.ganzhiYear) \(l.zodiac)").font(DS.font(compact ? 12 : 13, .medium)).foregroundStyle(DS.textSecondary)
                    Spacer()
                    statusTag(info)
                }
                if !compact {
                    Text(CN.full(d))
                        .font(DS.body).foregroundStyle(DS.textSecondary)
                }
                if !extra.isEmpty {
                    HStack(spacing: 6) { ForEach(extra, id: \.self) { Tag($0, color: DS.brand) } }
                }
                if let w = model.weather(on: d) {
                    HStack(spacing: 6) {
                        Image(systemName: w.symbol)
                        Text("\(w.text) \(Int(w.low.rounded()))° ~ \(Int(w.high.rounded()))°")
                    }
                    .font(DS.body)
                }
                Divider().overlay(DS.border)
                Label(model.countdownText(for: d), systemImage: "clock")
                    .font(DS.caption).foregroundStyle(DS.textSecondary)

                if !compact {
                    if !dayMeetings.isEmpty || meetingsSyncEnabled {
                        Divider().overlay(DS.border)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("当日会议与日程")
                                    .font(DS.font(13, .semibold))
                                    .foregroundStyle(DS.textSecondary)
                                Spacer()
                                if !dayMeetings.isEmpty {
                                    Text("\(dayMeetings.count) 场")
                                        .font(DS.caption.monospacedDigit())
                                        .foregroundStyle(DS.textTertiary)
                                }
                            }
                            if dayMeetings.isEmpty {
                                Text("当天暂无会议或日程")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textTertiary)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(dayMeetings) { event in
                                        MeetingEventRow(
                                            event: event,
                                            use24Hour: model.use24HourTime,
                                            canLogDraft: model.context.appendDailyLogDraft != nil,
                                            isLogged: loggedMeetingIDs.contains(event.id),
                                            onOpenURL: { url in
                                                NSWorkspace.shared.open(url)
                                            },
                                            onLogDraft: {
                                                if model.logMeeting(event, on: d) {
                                                    loggedMeetingIDs.insert(event.id)
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Divider().overlay(DS.border)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("当日待办与备忘")
                                .font(DS.font(13, .semibold))
                                .foregroundStyle(DS.textSecondary)
                            Spacer()
                            if !dayTodos.isEmpty {
                                let doneCount = dayTodos.filter(\.isCompleted).count
                                Text("\(doneCount)/\(dayTodos.count)")
                                    .font(DS.caption.monospacedDigit())
                                    .foregroundStyle(DS.textTertiary)
                            }
                        }

                        if dayTodos.isEmpty {
                            Text("当天暂无待办安排")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(dayTodos) { item in
                                    HStack(spacing: 8) {
                                        Button {
                                            model.context.todos.toggleCompleted(id: item.id)
                                        } label: {
                                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                                .font(DS.font(14))
                                                .foregroundStyle(item.isCompleted ? DS.success : DS.textTertiary)
                                        }
                                        .buttonStyle(.plain)

                                        Text(item.title)
                                            .font(DS.font(13))
                                            .strikethrough(item.isCompleted)
                                            .foregroundStyle(item.isCompleted ? DS.textTertiary : DS.text)
                                            .lineLimit(2)

                                        Spacer(minLength: 4)

                                        if item.priorityLevel != .normal && !item.isCompleted {
                                            Tag(item.priorityLevel.displayName, color: item.priorityLevel.tint)
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("添加当天待办或备忘…", text: $newTodoTitle)
                                .textFieldStyle(.ds)
                                .onSubmit { addTodo(on: d) }
                            Button {
                                addTodo(on: d)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.dsSecondary)
                            .disabled(newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } else {
                    if !dayMeetings.isEmpty {
                        Label("当日 \(dayMeetings.count) 场会议日程", systemImage: "video")
                            .font(DS.caption)
                            .foregroundStyle(DS.warning)
                    }
                    if !dayTodos.isEmpty {
                        let pendingCount = dayTodos.filter { !$0.isCompleted }.count
                        Label(pendingCount > 0 ? "当日待办 \(pendingCount) 项未完成" : "当日 \(dayTodos.count) 项待办均已完成", systemImage: "checklist")
                            .font(DS.caption)
                            .foregroundStyle(pendingCount > 0 ? DS.brand : DS.success)
                    }
                }
            }
        }
    }

    private func addTodo(on date: Date) {
        let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if model.context.todos.add(title: trimmed, dueDate: WorkCalendar.dayString(date)) != nil {
            newTodoTitle = ""
        }
    }

    @ViewBuilder
    func statusTag(_ info: DayInfo) -> some View {
        switch info.kind {
        case .workday: Tag("工作日", color: DS.textSecondary)
        case .weekend: Tag("休息", color: DS.success)
        case .holiday: Tag(info.name.map { "\($0) 放假" } ?? "放假", color: DS.success)
        case .makeupWorkday: Tag("调休上班", color: DS.danger)
        }
    }
}

private struct MeetingEventRow: View {
    let event: MeetingEvent
    let use24Hour: Bool
    let canLogDraft: Bool
    let isLogged: Bool
    let onOpenURL: (URL) -> Void
    let onLogDraft: () -> Void

    private var timeText: String {
        if event.isAllDay { return "全天" }
        let start = CalendarModel.formatShortTime(event.startDate, use24Hour: use24Hour)
        let end = CalendarModel.formatShortTime(event.endDate, use24Hour: use24Hour)
        return "\(start)–\(end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(DS.warning)
                    .frame(width: 6, height: 6)
                Text(event.title)
                    .font(DS.font(13, .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }

            HStack(spacing: 6) {
                Text(timeText)
                    .font(DS.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
                if !event.calendarTitle.isEmpty {
                    Text("· \(event.calendarTitle)")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let url = event.meetingURL {
                    Button("入会") {
                        onOpenURL(url)
                    }
                    .buttonStyle(.dsChip)
                }
                if canLogDraft {
                    Button(isLogged ? "已记草稿" : "+ 记日报") {
                        onLogDraft()
                    }
                    .buttonStyle(.dsChip)
                    .disabled(isLogged)
                }
            }
            .padding(.leading, 12)
        }
        .padding(.vertical, 4)
    }
}

// MARK: 天气

struct WeatherCard: View {
    let model: CalendarModel

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("天气").font(DS.sectionTitle).foregroundStyle(DS.textSecondary)
                    Spacer()
                    Button { Task { await model.refreshWeather() } } label: {
                        if model.isLoadingWeather { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.dsGhost)
                    .help("刷新天气")
                }
                if let w = model.weather {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: w.symbol).font(DS.font(30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(w.temperature.rounded()))°").font(DS.font(26, .semibold)).monospacedDigit()
                            let subtitle = if let aqi = w.aqi {
                                if let cat = w.resolvedAQICategory {
                                    "\(w.city) · \(w.text) · AQI \(aqi) \(cat)"
                                } else {
                                    "\(w.city) · \(w.text) · AQI \(aqi)"
                                }
                            } else {
                                "\(w.city) · \(w.text)"
                            }
                            Text(subtitle).font(DS.caption).foregroundStyle(DS.textSecondary)
                        }
                    }
                    VStack(spacing: 6) {
                        ForEach(w.days, id: \.date) { day in
                            HStack {
                                Text(weekdayText(day.date)).frame(width: DS.s(44), alignment: .leading)
                                Image(systemName: day.symbol).frame(width: DS.s(22))
                                Text(day.text).foregroundStyle(DS.textSecondary)
                                Spacer()
                                Text("\(Int(day.low.rounded()))° / \(Int(day.high.rounded()))°").monospacedDigit()
                            }
                            .font(DS.caption)
                        }
                    }
                    Text("更新于 \(CalendarModel.formatShortTime(w.fetchedAt, use24Hour: model.use24HourTime))")
                        .font(DS.font(11))
                        .foregroundStyle(DS.textTertiary)
                } else {
                    Text(model.weatherError ?? "还没选城市，选好后显示未来 7 天天气。").font(DS.body).foregroundStyle(DS.textSecondary)
                    Button("选择城市") { model.context.openSettings(CalendarPlugin.settingsWeatherID) }.buttonStyle(.dsSecondary)
                }
                if let e = model.weatherError, model.weather != nil {
                    Text(e).font(DS.caption).foregroundStyle(DS.danger)
                }
            }
        }
    }

    func weekdayText(_ key: String) -> String {
        guard let d = WorkCalendar.dayFormatterDate(key) else { return key }
        if CalendarModel.cal.isDateInToday(d) { return "今天" }
        if CalendarModel.cal.isDateInTomorrow(d) { return "明天" }
        return CN.weekdayShort(d)
    }
}

extension WorkCalendar {
    static func dayFormatterDate(_ key: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)
    }
}
