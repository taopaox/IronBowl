import AppKit
import Foundation
import IronBowlKit
import Testing
@testable import CalendarPlugin

private func makeDate(year: Int = 2026, month: Int = 11, day: Int = 25, hour: Int, minute: Int, second: Int = 0) -> Date {
    var c = DateComponents()
    c.year = year
    c.month = month
    c.day = day
    c.hour = hour
    c.minute = minute
    c.second = second
    return CalendarModel.cal.date(from: c)!
}

@Test func formatTimeAllCombinations() {
    let morning = makeDate(hour: 9, minute: 5, second: 7)
    #expect(CalendarModel.formatTime(morning, use24Hour: true, showPeriod: false, showSeconds: false) == "09:05")
    #expect(CalendarModel.formatTime(morning, use24Hour: true, showPeriod: true, showSeconds: true) == "上午 09:05:07")
    #expect(CalendarModel.formatTime(morning, use24Hour: false, showPeriod: false, showSeconds: false) == "9:05")
    #expect(CalendarModel.formatTime(morning, use24Hour: false, showPeriod: true, showSeconds: true) == "上午 9:05:07")

    let afternoon = makeDate(hour: 16, minute: 4, second: 9)
    #expect(CalendarModel.formatTime(afternoon, use24Hour: true, showPeriod: false, showSeconds: false) == "16:04")
    #expect(CalendarModel.formatTime(afternoon, use24Hour: true, showPeriod: true, showSeconds: true) == "下午 16:04:09")
    #expect(CalendarModel.formatTime(afternoon, use24Hour: false, showPeriod: false, showSeconds: false) == "4:04")
    #expect(CalendarModel.formatTime(afternoon, use24Hour: false, showPeriod: true, showSeconds: true) == "下午 4:04:09")

    let midnight = makeDate(hour: 0, minute: 5, second: 3)
    #expect(CalendarModel.formatTime(midnight, use24Hour: true, showPeriod: false, showSeconds: false) == "00:05")
    #expect(CalendarModel.formatTime(midnight, use24Hour: false, showPeriod: false, showSeconds: false) == "12:05")
    #expect(CalendarModel.formatTime(midnight, use24Hour: false, showPeriod: true, showSeconds: false) == "上午 12:05")

    let noon = makeDate(hour: 12, minute: 5, second: 3)
    #expect(CalendarModel.formatTime(noon, use24Hour: true, showPeriod: false, showSeconds: false) == "12:05")
    #expect(CalendarModel.formatTime(noon, use24Hour: false, showPeriod: false, showSeconds: false) == "12:05")
    #expect(CalendarModel.formatTime(noon, use24Hour: false, showPeriod: true, showSeconds: false) == "下午 12:05")
}

@Test func menuBarSegmentsCombinations() {
    let date = makeDate(hour: 16, minute: 4, second: 9)
    let weather = WeatherSnapshot(
        city: "深圳",
        temperature: 23.4,
        text: "晴",
        symbol: "sun.max",
        days: [],
        fetchedAt: date,
        aqi: 42,
        aqiCategory: "优"
    )

    // 默认配置（含天气，不含 AQI、农历、秒、icon、上午/下午）
    let defaultSegments = CalendarModel.menuBarSegments(at: date, weather: weather, config: MenuBarDisplayConfig())
    #expect(defaultSegments == [
        .symbol("sun.max"),
        .text("23°"),
        .text("11月25日"),
        .text("周三"),
        .text("16:04"),
    ])

    // 全开配置
    let fullConfig = MenuBarDisplayConfig(
        timeEnabled: true,
        timeShowIcon: true,
        timeUse24Hour: false,
        timeShowPeriod: true,
        timeShowSeconds: true,
        dateEnabled: true,
        dateShowLunar: true,
        dateShowSolar: true,
        dateShowWeekday: true,
        weatherEnabled: true,
        weatherShowWeather: true,
        weatherShowAQI: true
    )
    #expect(CalendarModel.menuBarSegments(at: date, weather: weather, config: fullConfig) == [
        .symbol("sun.max"),
        .text("23°"),
        .text("AQI 42"),
        .text("11月25日"),
        .text("周三"),
        .text("十月十七"),
        .symbol("clock"),
        .text("下午 4:04:09"),
    ])

    // 仅开空气质量 AQI，不开天气图标温度
    let aqiOnlyConfig = MenuBarDisplayConfig(
        timeEnabled: false,
        dateEnabled: false,
        weatherEnabled: true,
        weatherShowWeather: false,
        weatherShowAQI: true
    )
    #expect(CalendarModel.menuBarSegments(at: date, weather: weather, config: aqiOnlyConfig) == [
        .text("AQI 42"),
    ])

    // 仅开农历
    let lunarOnlyConfig = MenuBarDisplayConfig(
        timeEnabled: false,
        dateEnabled: true,
        dateShowLunar: true,
        dateShowSolar: false,
        dateShowWeekday: false,
        weatherEnabled: false
    )
    #expect(CalendarModel.menuBarSegments(at: date, weather: weather, config: lunarOnlyConfig) == [
        .text("十月十七"),
    ])

    // 父开关全关闭时子开关不生效
    let allDisabledConfig = MenuBarDisplayConfig(
        timeEnabled: false,
        timeShowIcon: true,
        timeShowSeconds: true,
        dateEnabled: false,
        dateShowLunar: true,
        dateShowSolar: true,
        dateShowWeekday: true,
        weatherEnabled: false,
        weatherShowWeather: true,
        weatherShowAQI: true
    )
    #expect(CalendarModel.menuBarSegments(at: date, weather: weather, config: allDisabledConfig).isEmpty)

    // 天气为空时优雅省略天气与 AQI 段
    #expect(CalendarModel.menuBarSegments(at: date, weather: nil, config: fullConfig) == [
        .text("11月25日"),
        .text("周三"),
        .text("十月十七"),
        .symbol("clock"),
        .text("下午 4:04:09"),
    ])
}

@Test func weatherSnapshotLegacyDecodingAndAQICategory() throws {
    let legacyJSON = """
    {
      "city": "深圳",
      "temperature": 24.5,
      "text": "晴",
      "symbol": "sun.max",
      "days": [],
      "fetchedAt": 0
    }
    """
    let decoded = try JSONDecoder().decode(WeatherSnapshot.self, from: Data(legacyJSON.utf8))
    #expect(decoded.city == "深圳")
    #expect(decoded.aqi == nil)
    #expect(decoded.aqiCategory == nil)
    #expect(decoded.resolvedAQICategory == nil)

    #expect(WeatherSnapshot.aqiCategory(for: 0) == "优")
    #expect(WeatherSnapshot.aqiCategory(for: 50) == "优")
    #expect(WeatherSnapshot.aqiCategory(for: 51) == "良")
    #expect(WeatherSnapshot.aqiCategory(for: 100) == "良")
    #expect(WeatherSnapshot.aqiCategory(for: 101) == "轻度")
    #expect(WeatherSnapshot.aqiCategory(for: 150) == "轻度")
    #expect(WeatherSnapshot.aqiCategory(for: 151) == "中度")
    #expect(WeatherSnapshot.aqiCategory(for: 200) == "中度")
    #expect(WeatherSnapshot.aqiCategory(for: 201) == "重度")
    #expect(WeatherSnapshot.aqiCategory(for: 300) == "重度")
    #expect(WeatherSnapshot.aqiCategory(for: 301) == "严重")

    let withFallbackCategory = WeatherSnapshot(
        city: "深圳",
        temperature: 22,
        text: "晴",
        symbol: "sun.max",
        days: [],
        fetchedAt: Date(),
        aqi: 88,
        aqiCategory: nil
    )
    #expect(withFallbackCategory.resolvedAQICategory == "良")

    let withExplicitCategory = WeatherSnapshot(
        city: "深圳",
        temperature: 22,
        text: "晴",
        symbol: "sun.max",
        days: [],
        fetchedAt: Date(),
        aqi: 88,
        aqiCategory: "良好"
    )
    #expect(withExplicitCategory.resolvedAQICategory == "良好")
}

@MainActor @Test func menuBarSettingsKeysPersistAndDriveSecondTick() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ib-cal-menubar-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)

    // 默认值验证
    #expect(settings[CalendarKeys.menuBarEnabled] == true)
    #expect(settings[CalendarKeys.menuBarTime] == true)
    #expect(settings[CalendarKeys.menuBarTimeIcon] == false)
    #expect(settings[CalendarKeys.menuBarTime24Hour] == true)
    #expect(settings[CalendarKeys.menuBarTimePeriod] == false)
    #expect(settings[CalendarKeys.menuBarTimeSeconds] == false)
    #expect(settings[CalendarKeys.menuBarDateSection] == true)
    #expect(settings[CalendarKeys.menuBarLunar] == false)
    #expect(settings[CalendarKeys.menuBarDate] == true)
    #expect(settings[CalendarKeys.menuBarWeekday] == true)
    #expect(settings[CalendarKeys.menuBarWeatherSection] == true)
    #expect(settings[CalendarKeys.menuBarWeather] == true)
    #expect(settings[CalendarKeys.menuBarAQI] == false)

    // 写入并重载
    settings[CalendarKeys.menuBarTimeIcon] = true
    settings[CalendarKeys.menuBarTime24Hour] = false
    settings[CalendarKeys.menuBarTimePeriod] = true
    settings[CalendarKeys.menuBarTimeSeconds] = true
    settings[CalendarKeys.menuBarDateSection] = false
    settings[CalendarKeys.menuBarLunar] = true
    settings[CalendarKeys.menuBarWeatherSection] = false
    settings[CalendarKeys.menuBarAQI] = true

    let reloaded = SettingsStore(database: db)
    #expect(reloaded[CalendarKeys.menuBarTimeIcon] == true)
    #expect(reloaded[CalendarKeys.menuBarTime24Hour] == false)
    #expect(reloaded[CalendarKeys.menuBarTimePeriod] == true)
    #expect(reloaded[CalendarKeys.menuBarTimeSeconds] == true)
    #expect(reloaded[CalendarKeys.menuBarDateSection] == false)
    #expect(reloaded[CalendarKeys.menuBarLunar] == true)
    #expect(reloaded[CalendarKeys.menuBarWeatherSection] == false)
    #expect(reloaded[CalendarKeys.menuBarAQI] == true)

    let context = PluginContext(
        database: db,
        settings: reloaded,
        reminders: ReminderCenter(),
        workCalendar: WorkCalendar(database: db, settings: reloaded),
        providers: AIProviderStore(settings: reloaded),
        openPlugin: { _ in },
        openSettings: { _ in }
    )
    let model = CalendarModel(context: context)
    #expect(model.needsSecondTick == true)

    reloaded[CalendarKeys.menuBarTime] = false
    #expect(model.needsSecondTick == false)

    reloaded[CalendarKeys.menuBarTime] = true
    reloaded[CalendarKeys.menuBarTimeSeconds] = false
    #expect(model.needsSecondTick == false)
}

@MainActor @Test func calendarSettingsPagesOrderAndLifecycle() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ib-cal-pages-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let plugin = CalendarPlugin()
    #expect(plugin.settingsPages.isEmpty)

    let db = try AppDatabase(url: url, migrations: plugin.migrations)
    let settings = SettingsStore(database: db)
    let context = PluginContext(
        database: db,
        settings: settings,
        reminders: ReminderCenter(),
        workCalendar: WorkCalendar(database: db, settings: settings),
        providers: AIProviderStore(settings: settings),
        openPlugin: { _ in },
        openSettings: { _ in }
    )

    plugin.start(context: context)
    let pages = plugin.settingsPages
    #expect(pages.map(\.id) == [
        CalendarPlugin.settingsDisplayID,
        CalendarPlugin.settingsStatusBarID,
        CalendarPlugin.settingsAppearanceID,
        CalendarPlugin.settingsHolidaysID,
        CalendarPlugin.settingsWeatherID,
    ])
    #expect(pages.map(\.title) == ["月历", "状态栏", "外观", "节假日", "天气"])
    #expect(Set(pages.map(\.id)).count == 5)
    #expect(pages.allSatisfy { !$0.systemImage.isEmpty })

    plugin.stop()
    #expect(plugin.settingsPages.isEmpty)
}

@MainActor @Test func menuBarImageRendererProducesValidTemplateImages() throws {
    func hasVisiblePixels(_ image: NSImage) -> Bool {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = rep.bitmapData else { return false }
        let totalBytes = rep.bytesPerRow * rep.pixelsHigh
        for offset in stride(from: 3, to: totalBytes, by: 4) where data[offset] > 0 {
            return true
        }
        return false
    }

    // 空分段回退到日历图标
    let fallback = CalendarMenuBarRenderer.renderImage(segments: [], scale: 2.0)
    #expect(fallback.isTemplate == true)
    #expect(fallback.size.height == CalendarMenuBarRenderer.barHeight)
    #expect(fallback.size.width >= 18)
    let fallbackRep = try #require(fallback.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    #expect(fallbackRep.pixelsWide == Int(ceil(fallback.size.width * 2)))
    #expect(fallbackRep.pixelsHigh == 44)
    #expect(hasVisiblePixels(fallback))

    // 仅时间
    let timeOnly = CalendarMenuBarRenderer.renderImage(segments: [.text("09:05")], scale: 2.0)
    #expect(timeOnly.isTemplate == true)
    #expect(timeOnly.size.height == CalendarMenuBarRenderer.barHeight)
    #expect(hasVisiblePixels(timeOnly))

    // 日期 + 星期 + 时间
    let dateTime = CalendarMenuBarRenderer.renderImage(
        segments: [.text("11月26日"), .text("周四"), .text("09:05")],
        scale: 2.0
    )
    #expect(dateTime.isTemplate == true)
    #expect(dateTime.size.width > timeOnly.size.width)
    #expect(hasVisiblePixels(dateTime))

    // 全开（含两个 SF Symbol 与多段文字）宽度明显大于仅日期+时间，不会丢失任何段
    let full = CalendarMenuBarRenderer.renderImage(
        segments: [.symbol("sun.max"), .text("10°"), .text("11月26日"), .text("周四"), .symbol("clock"), .text("09:05")],
        scale: 2.0
    )
    #expect(full.isTemplate == true)
    #expect(full.size.height == CalendarMenuBarRenderer.barHeight)
    #expect(full.size.width > dateTime.size.width)
    #expect(hasVisiblePixels(full))
}
