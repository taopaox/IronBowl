import AppKit
import IronBowlKit
import SwiftUI

/// 菜单栏日历的文字：天气图标 + 「13° 11月25日 周三 12:25」。
public struct CalendarMenuBarLabel: View {
    let model: CalendarModel

    public init(model: CalendarModel) { self.model = model }

    public var body: some View {
        let text = model.menuBarText
        if let symbol = model.menuBarSymbol {
            Text("\(Image(systemName: symbol)) \(text)")
        } else {
            Text(text.isEmpty ? "\(Image(systemName: "calendar"))" : text)
        }
    }
}

/// 点菜单栏日历弹出的面板：左边月历，右边时间、日期块、天气、农历。
public struct CalendarPopover: View {
    let model: CalendarModel

    public init(model: CalendarModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            MonthCard(model: model, compact: true, bordered: false)
                .frame(width: DS.s(380))
            Rectangle().fill(DS.border).frame(width: 1)
            SidePanel(model: model)
                .frame(width: DS.s(140))
        }
        .background(DS.canvas)
        .onAppear { model.goToday() }
    }
}

private struct SidePanel: View {
    let model: CalendarModel

    var body: some View {
        let d = model.selected
        let l = Lunar.lunar(d)
        let extra = [Lunar.festival(d), Lunar.solarTerm(d)].compactMap { $0 }
        VStack(spacing: 10) {
            Text(CN.time(model.now))
                .font(DS.font(28, .medium)).monospacedDigit()
                .padding(.top, 6)
            Text(CN.weekday(d)).font(DS.font(14, .medium))
            Text("\(CalendarModel.cal.component(.day, from: d))")
                .font(DS.font(34, .semibold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: DS.s(72), height: DS.s(72))
                .background(DS.brand, in: .rect(cornerRadius: 12))
            weather
            Divider().overlay(DS.border).padding(.horizontal, 8)
            VStack(spacing: 4) {
                Text("\(l.ganzhiYear)【\(l.zodiac)年】").font(DS.font(12.5, .medium))
                Text(l.text).font(DS.font(14, .medium))
                ForEach(extra, id: \.self) { Tag($0, color: DS.brand) }
                if let badge = model.dayBadge(d) {
                    Tag(badge == "休" ? "放假" : "调休上班", color: badge == "休" ? DS.success : DS.danger)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.context.openSettings(CalendarPlugin.settingsWeatherID)
            } label: {
                Label(model.weather?.city ?? model.settings[CalendarKeys.city]?.name ?? "设置城市", systemImage: "location")
                    .lineLimit(1)
            }
            .buttonStyle(.dsGhost)
            HStack(spacing: 2) {
                Button { model.context.openPlugin(CalendarPlugin.pluginID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.dsGhost).help("打开大窗口")
                Button { model.context.openSettings("calendar.display") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.dsGhost).help("日历设置")
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .background(DS.sidebar)
    }

    @ViewBuilder
    private var weather: some View {
        if let w = model.weather(on: model.selected) {
            VStack(spacing: 2) {
                Image(systemName: w.symbol).font(DS.font(20))
                Text("\(Int(w.low.rounded()))° ~ \(Int(w.high.rounded()))°").font(DS.caption).monospacedDigit()
                Text(w.text).font(DS.caption).foregroundStyle(DS.textSecondary)
            }
        } else if model.weather == nil {
            Text("N/A").font(DS.font(18, .medium)).foregroundStyle(DS.textTertiary)
        } else {
            Text("暂无预报").font(DS.caption).foregroundStyle(DS.textTertiary)
        }
    }
}
