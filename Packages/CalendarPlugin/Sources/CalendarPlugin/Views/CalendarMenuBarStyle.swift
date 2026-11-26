import Foundation
import IronBowlKit

/// 状态栏日历显示风格分类。
public nonisolated enum CalendarMenuBarStyleCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case minimal
    case dense
    case badge
    case cultural
    case tech

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimal: "极简原生"
        case .dense: "双行高密"
        case .badge: "徽章卡片"
        case .cultural: "国风创意"
        case .tech: "仪表科技"
        }
    }
}

/// 状态栏日历 20 套可选视觉风格。
public nonisolated enum CalendarMenuBarStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case microDashboard
    case nativeMinimal
    case tearOffTile
    case liquidGlass
    case vermilionSeal
    case swissChrono
    case splitRibbon
    case daylightTrack
    case casioLCD
    case softClay
    case terminalStream
    case analogWatch
    case weatherAura
    case editorialSerif
    case avionicsHUD
    case cyberNeon
    case washiStationery
    case notchCompact
    case semanticChips
    case heroClock

    public var id: String { rawValue }

    public var code: String {
        switch self {
        case .microDashboard: "01"
        case .nativeMinimal: "02"
        case .tearOffTile: "03"
        case .liquidGlass: "04"
        case .vermilionSeal: "05"
        case .swissChrono: "06"
        case .splitRibbon: "07"
        case .daylightTrack: "08"
        case .casioLCD: "09"
        case .softClay: "10"
        case .terminalStream: "11"
        case .analogWatch: "12"
        case .weatherAura: "13"
        case .editorialSerif: "14"
        case .avionicsHUD: "15"
        case .cyberNeon: "16"
        case .washiStationery: "17"
        case .notchCompact: "18"
        case .semanticChips: "19"
        case .heroClock: "20"
        }
    }

    public var displayName: String {
        switch self {
        case .microDashboard: "双行微缩仪表卡"
        case .nativeMinimal: "原生极简排印"
        case .tearOffTile: "迷你撕页日历"
        case .liquidGlass: "液态玻璃胶囊"
        case .vermilionSeal: "东方朱砂印章"
        case .swissChrono: "瑞士精密计时"
        case .splitRibbon: "双色拼接胶片"
        case .daylightTrack: "日晷昼夜进度"
        case .casioLCD: "复古卡西欧 LCD"
        case .softClay: "软萌毛毡云朵"
        case .terminalStream: "极客终端语法"
        case .analogWatch: "实时模拟表盘"
        case .weatherAura: "气象光晕色温"
        case .editorialSerif: "报刊衬线排印"
        case .avionicsHUD: "航空座舱 HUD"
        case .cyberNeon: "赛博霓虹光边"
        case .washiStationery: "日式和纸手帐"
        case .notchCompact: "刘海极致省宽"
        case .semanticChips: "语义微胶囊群"
        case .heroClock: "呼吸大时钟"
        }
    }

    public var subtitle: String {
        switch self {
        case .microDashboard: "双行语义色分栏 · 透明高密度"
        case .nativeMinimal: "苹果原生克制排版 · 零装饰"
        case .tearOffTile: "朱红月眉白底日格 · 物理桌历"
        case .liquidGlass: "高光半透明分格胶囊"
        case .vermilionSeal: "朱砂方印 · 宋体农历节令"
        case .swissChrono: "博朗红点 · 反白方框星期"
        case .splitRibbon: "暖橙天气头 · 磨砂日期尾"
        case .daylightTrack: "昼夜渐变光轨 · 实时太阳点"
        case .casioLCD: "墨绿液晶表窗 · 等宽数码"
        case .softClay: "暖橙柔边药丸 · 圆润亲和"
        case .terminalStream: "语法高亮等宽流 · 竖线分隔"
        case .analogWatch: "实时走动指针 · 极简副标"
        case .weatherAura: "晴暖雨冷大气光晕渐隐带"
        case .editorialSerif: "宋体数字农历 · 细竖线书卷感"
        case .avionicsHUD: "青色边界线 · 大写遥测字段头"
        case .cyberNeon: "黑曜石底 · 青紫粉流光底边"
        case .washiStationery: "温润纸感 · 方框星期印"
        case .notchCompact: "双列高密叠排 · 极限省宽"
        case .semanticChips: "分域彩色小徽章 · 橙色时刻"
        case .heroClock: "大号时钟领衔 · 轻语双行副标"
        }
    }

    public var category: CalendarMenuBarStyleCategory {
        switch self {
        case .nativeMinimal, .swissChrono, .heroClock: .minimal
        case .microDashboard, .notchCompact: .dense
        case .tearOffTile, .liquidGlass, .splitRibbon, .weatherAura, .semanticChips: .badge
        case .vermilionSeal, .softClay, .editorialSerif, .washiStationery: .cultural
        case .daylightTrack, .casioLCD, .terminalStream, .analogWatch, .avionicsHUD, .cyberNeon: .tech
        }
    }
}

/// 供状态栏多风格渲染器消费的结构化实时数据快照。
public nonisolated struct CalendarMenuBarSnapshot: Sendable, Equatable {
    public let showLogo: Bool

    public let weatherEnabled: Bool
    public let weatherSymbol: String?
    public let weatherText: String?
    public let temperatureText: String?
    public let aqi: Int?
    public let aqiCategory: String?

    public let dateEnabled: Bool
    public let month: Int
    public let day: Int
    public let solarText: String?
    public let solarSlash: String?
    public let solarDash: String?
    public let solarDot: String?
    public let weekdayShort: String?
    public let weekdaySingle: String?
    public let weekdayEN: String?
    public let lunarText: String?
    public let lunarDay: String?
    public let holidayBadge: String?

    public let timeEnabled: Bool
    public let timeShowIcon: Bool
    public let timeUse24Hour: Bool
    public let timeShowPeriod: Bool
    public let timeShowSeconds: Bool
    public let timePeriod: String?
    public let timePeriodEN: String
    public let timeHM: String
    public let timeSeconds: String
    public let timeFull: String
    public let timeFormatted: String
    public let hour24: Int
    public let minute: Int
    public let second: Int
    public let dayProgress: Double

    public init(
        showLogo: Bool,
        weatherEnabled: Bool,
        weatherSymbol: String?,
        weatherText: String?,
        temperatureText: String?,
        aqi: Int?,
        aqiCategory: String?,
        dateEnabled: Bool,
        month: Int,
        day: Int,
        solarText: String?,
        solarSlash: String?,
        solarDash: String?,
        solarDot: String?,
        weekdayShort: String?,
        weekdaySingle: String?,
        weekdayEN: String?,
        lunarText: String?,
        lunarDay: String?,
        holidayBadge: String?,
        timeEnabled: Bool,
        timeShowIcon: Bool,
        timeUse24Hour: Bool,
        timeShowPeriod: Bool,
        timeShowSeconds: Bool,
        timePeriod: String?,
        timePeriodEN: String,
        timeHM: String,
        timeSeconds: String,
        timeFull: String,
        timeFormatted: String,
        hour24: Int,
        minute: Int,
        second: Int,
        dayProgress: Double
    ) {
        self.showLogo = showLogo
        self.weatherEnabled = weatherEnabled
        self.weatherSymbol = weatherSymbol
        self.weatherText = weatherText
        self.temperatureText = temperatureText
        self.aqi = aqi
        self.aqiCategory = aqiCategory
        self.dateEnabled = dateEnabled
        self.month = month
        self.day = day
        self.solarText = solarText
        self.solarSlash = solarSlash
        self.solarDash = solarDash
        self.solarDot = solarDot
        self.weekdayShort = weekdayShort
        self.weekdaySingle = weekdaySingle
        self.weekdayEN = weekdayEN
        self.lunarText = lunarText
        self.lunarDay = lunarDay
        self.holidayBadge = holidayBadge
        self.timeEnabled = timeEnabled
        self.timeShowIcon = timeShowIcon
        self.timeUse24Hour = timeUse24Hour
        self.timeShowPeriod = timeShowPeriod
        self.timeShowSeconds = timeShowSeconds
        self.timePeriod = timePeriod
        self.timePeriodEN = timePeriodEN
        self.timeHM = timeHM
        self.timeSeconds = timeSeconds
        self.timeFull = timeFull
        self.timeFormatted = timeFormatted
        self.hour24 = hour24
        self.minute = minute
        self.second = second
        self.dayProgress = dayProgress
    }

    public var hasWeatherPart: Bool {
        weatherEnabled && (temperatureText != nil || aqi != nil)
    }

    public var hasDatePart: Bool {
        solarText != nil || weekdayShort != nil || lunarText != nil || holidayBadge != nil
    }

    public var hasAnyContent: Bool {
        showLogo || hasWeatherPart || hasDatePart || timeEnabled
    }

    public static func make(
        at date: Date,
        weather: WeatherSnapshot?,
        holidayBadge: String?,
        config: MenuBarDisplayConfig
    ) -> CalendarMenuBarSnapshot {
        let cal = CalendarModel.cal
        let comp = cal.dateComponents([.month, .day, .weekday, .hour, .minute, .second], from: date)
        let month = comp.month ?? 1
        let day = comp.day ?? 1
        let weekdayIndex = max(0, min(6, (comp.weekday ?? 1) - 1))
        let hour = comp.hour ?? 0
        let minute = comp.minute ?? 0
        let second = comp.second ?? 0

        let singleWeekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let enWeekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

        let showWeatherInfo = config.weatherEnabled && config.weatherShowWeather && weather != nil
        let showAQIInfo = config.weatherEnabled && config.weatherShowAQI && weather?.aqi != nil

        let lunar = Lunar.lunar(date)
        let showSolar = config.dateEnabled && config.dateShowSolar
        let showWeekday = config.dateEnabled && config.dateShowWeekday
        let showLunar = config.dateEnabled && config.dateShowLunar

        let timeHM = CalendarModel.formatTime(
            date,
            use24Hour: config.timeUse24Hour,
            showPeriod: false,
            showSeconds: false
        )
        let timeFull = CalendarModel.formatTime(
            date,
            use24Hour: config.timeUse24Hour,
            showPeriod: false,
            showSeconds: config.timeShowSeconds
        )
        let timeFormatted = CalendarModel.formatTime(
            date,
            use24Hour: config.timeUse24Hour,
            showPeriod: config.timeShowPeriod,
            showSeconds: config.timeShowSeconds
        )
        let periodZH = hour < 12 ? "上午" : "下午"
        let periodEN = hour < 12 ? "AM" : "PM"
        let progress = min(0.98, max(0.02, Double(hour * 60 + minute) / 1440.0))

        return CalendarMenuBarSnapshot(
            showLogo: config.showLogo,
            weatherEnabled: config.weatherEnabled,
            weatherSymbol: showWeatherInfo ? weather?.symbol : nil,
            weatherText: showWeatherInfo ? weather?.text : nil,
            temperatureText: showWeatherInfo ? weather.map { "\(Int($0.temperature.rounded()))°" } : nil,
            aqi: showAQIInfo ? weather?.aqi : nil,
            aqiCategory: showAQIInfo ? weather?.resolvedAQICategory : nil,
            dateEnabled: config.dateEnabled,
            month: month,
            day: day,
            solarText: showSolar ? CN.monthDay(date) : nil,
            solarSlash: showSolar ? CN.slash(date) : nil,
            solarDash: showSolar ? String(format: "%02d-%02d", month, day) : nil,
            solarDot: showSolar ? String(format: "%02d.%02d", day, month) : nil,
            weekdayShort: showWeekday ? CN.weekdayShort(date) : nil,
            weekdaySingle: showWeekday ? singleWeekdays[weekdayIndex] : nil,
            weekdayEN: showWeekday ? enWeekdays[weekdayIndex] : nil,
            lunarText: showLunar ? lunar.text : nil,
            lunarDay: showLunar ? lunar.dayName : nil,
            holidayBadge: (config.dateEnabled && config.showHolidayBadge) ? holidayBadge : nil,
            timeEnabled: config.timeEnabled,
            timeShowIcon: config.timeShowIcon,
            timeUse24Hour: config.timeUse24Hour,
            timeShowPeriod: config.timeShowPeriod,
            timeShowSeconds: config.timeShowSeconds,
            timePeriod: config.timeShowPeriod ? periodZH : nil,
            timePeriodEN: periodEN,
            timeHM: timeHM,
            timeSeconds: String(format: "%02d", second),
            timeFull: timeFull,
            timeFormatted: timeFormatted,
            hour24: hour,
            minute: minute,
            second: second,
            dayProgress: progress
        )
    }
}
