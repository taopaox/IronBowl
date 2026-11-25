import Foundation
import IronBowlKit
import SwiftUI

/// 万年历插件：参照百度"今天"日历的布局，农历、节气、节日、休/班、倒计时、天气。
public final class CalendarPlugin: IronBowlPlugin {
    public static let pluginID = "calendar"
    public static let settingsWeatherID = "calendar.weather"
    public let id = CalendarPlugin.pluginID
    public let title = "万年历"
    public let systemImage = "calendar"

    public private(set) var model: CalendarModel?

    public init() {}

    public func start(context: PluginContext) {
        let model = CalendarModel(context: context)
        self.model = model
        model.start()
    }

    public func makeMainView() -> AnyView {
        guard let model else { return AnyView(ProgressView()) }
        return AnyView(CalendarMainView(model: model))
    }

    /// 菜单栏日历是否显示（工作台和独立版都用）。
    public var menuBarCalendarShown: Bool {
        get { model?.menuBarEnabled ?? false }
        set { model?.menuBarEnabled = newValue }
    }

    public var settingsPages: [SettingsPage] {
        guard let model else { return [] }
        return [
            SettingsPage(id: "calendar.display", title: "月历", systemImage: "calendar") { AnyView(CalendarDisplaySettings(model: model)) },
            SettingsPage(id: Self.settingsWeatherID, title: "天气", systemImage: "cloud.sun") { AnyView(WeatherSettings(model: model)) },
        ]
    }

    public var menuBarItems: [MenuBarItem] {
        guard let model else { return [] }
        return [
            MenuBarItem(id: "calendar.date", title: "日期（11月25日 周三）") {
                CN.monthDay(Date()) + " " + CN.weekdayShort(Date())
            },
            MenuBarItem(id: "calendar.lunar", title: "农历（十月十七）") { Lunar.lunar(Date()).text },
            MenuBarItem(id: "calendar.weather", title: "天气（晴 12°）") { model.weatherShort },
        ]
    }

    public var quickActions: [QuickAction] {
        guard let model else { return [] }
        return [
            QuickAction(id: "calendar.open", title: "看日历", systemImage: "calendar") {
                model.goToday()
                model.context.openPlugin(Self.pluginID)
            },
        ]
    }

    public var homeCards: [HomeCard] {
        guard let model else { return [] }
        return [
            HomeCard(id: "calendar.weather", label: model.weather?.city ?? "天气",
                     value: { model.weatherShort ?? "未设置" },
                     detail: {
                         guard let d = model.weather?.days.first else { return "选个城市看天气" }
                         return "今天 \(Int(d.low.rounded()))° ~ \(Int(d.high.rounded()))°"
                     },
                     action: { model.context.openPlugin(Self.pluginID) }),
        ]
    }
}
