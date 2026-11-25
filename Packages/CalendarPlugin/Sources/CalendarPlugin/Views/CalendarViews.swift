import IronBowlKit
import SwiftUI

/// 万年历主页面：左边月历，右边当天详情 + 天气。
public struct CalendarMainView: View {
    let model: CalendarModel

    public init(model: CalendarModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("万年历") {
                EmptyView()
            } actions: {
                if let w = model.weatherShort {
                    Label(w, systemImage: model.weather?.symbol ?? "cloud").font(DS.body).foregroundStyle(DS.textSecondary)
                }
            }
            .padding(.top, 8)
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
                    ForEach(model.cells) { cell in
                        DayCellView(model: model, cell: cell, compact: compact)
                    }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !compact {
                DSPicker(selection: Binding<Date?>(get: { nil }, set: { if let d = $0 { model.select(d) } }),
                         options: [(nil, "假期")] + model.workCalendar.holidays(inYear: model.year).map { (Date?.some($0.date), $0.name) })
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
    @State private var hovering = false

    var body: some View {
        let cal = CalendarModel.cal
        let isToday = cal.isDate(cell.date, inSameDayAs: model.now)
        let isSelected = cal.isDate(cell.date, inSameDayAs: model.selected)
        let info = model.workCalendar.dayInfo(cell.date)
        let weekday = cal.component(.weekday, from: cell.date)
        let red = info.kind == .holiday || ((weekday == 1 || weekday == 7) && info.kind != .makeupWorkday)
        let label = Lunar.cellLabel(cell.date)
        let badge = model.dayBadge(cell.date)

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
                    .foregroundStyle(label.isSpecial ? DS.brand : DS.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DS.s(compact ? 40 : 58))
            .opacity(cell.inMonth ? 1 : 0.35)
            .background(isSelected || hovering ? DS.hover : .clear, in: .rect(cornerRadius: 8))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(DS.brand, lineWidth: 1.5)
                } else if isSelected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(DS.borderStrong, lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isToday {
                    Text("今").font(DS.font(9, .semibold)).foregroundStyle(.white)
                        .frame(width: 14, height: 14).background(DS.brand, in: .rect(cornerRadius: 4))
                        .offset(x: -3, y: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                if let badge, cell.inMonth || !compact {
                    Text(badge).font(DS.font(9, .semibold))
                        .foregroundStyle(badge == "休" ? DS.success : DS.textSecondary)
                        .padding(.horizontal, 3)
                        .background((badge == "休" ? DS.success : DS.textSecondary).opacity(0.12), in: .rect(cornerRadius: 3))
                        .offset(x: 3, y: 3)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: 当天详情

struct DayDetailCard: View {
    let model: CalendarModel
    let compact: Bool

    var body: some View {
        let d = model.selected
        let l = Lunar.lunar(d)
        let info = model.workCalendar.dayInfo(d)
        let extra = [Lunar.festival(d), Lunar.solarTerm(d)].compactMap { $0 }
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
            }
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
                            Text("\(w.city) · \(w.text)").font(DS.caption).foregroundStyle(DS.textSecondary)
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
                    Text("更新于 \(CN.time(w.fetchedAt))").font(DS.font(11)).foregroundStyle(DS.textTertiary)
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
