import IronBowlKit
import SwiftUI

struct CalendarDisplaySettings: View {
    let model: CalendarModel

    var body: some View {
        let s = model.settings
        DSSection("月历", footer: "每周第一天作用于主窗口月历与状态栏弹出面板；节假日与调休数据可在左侧「节假日」中管理。") {
            DSRow("每周第一天") {
                DSPicker(
                    selection: s.binding(CalendarKeys.firstWeekday),
                    options: [
                        DSPickerOption(2, title: "周一", subtitle: "按国内习惯，周一排在月历第一列。"),
                        DSPickerOption(1, title: "周日", subtitle: "按国际习惯，周日排在月历第一列。"),
                    ]
                )
            }
        }
    }
}

struct CalendarStatusBarSettings: View {
    let model: CalendarModel

    private var s: SettingsStore { model.settings }

    private var dateEnabled: Binding<Bool> {
        Binding(
            get: { s[CalendarKeys.menuBarDateSection] },
            set: { on in
                s[CalendarKeys.menuBarDateSection] = on
                if on, !s[CalendarKeys.menuBarLunar], !s[CalendarKeys.menuBarDate], !s[CalendarKeys.menuBarWeekday] {
                    s[CalendarKeys.menuBarDate] = true
                }
            }
        )
    }

    private var weatherEnabled: Binding<Bool> {
        Binding(
            get: { s[CalendarKeys.menuBarWeatherSection] },
            set: { on in
                s[CalendarKeys.menuBarWeatherSection] = on
                if on, !s[CalendarKeys.menuBarWeather], !s[CalendarKeys.menuBarAQI] {
                    s[CalendarKeys.menuBarWeather] = true
                }
            }
        )
    }

    private var aqiEnabled: Binding<Bool> {
        Binding(
            get: { s[CalendarKeys.menuBarAQI] },
            set: { on in
                s[CalendarKeys.menuBarAQI] = on
                if on, s[CalendarKeys.city] != nil, model.weather?.aqi == nil {
                    Task { await model.refreshWeather() }
                }
            }
        )
    }

    var body: some View {
        Group {
            DSSection("状态栏日历", footer: "在顶部状态栏单独显示一个日历，点开就是月历。按住 ⌘ 可以拖动调整它在状态栏的位置。") {
                DSRow("在状态栏显示日历") { DSToggle(isOn: s.binding(CalendarKeys.menuBarEnabled)) }
                if s[CalendarKeys.menuBarEnabled] {
                    DSRow("当前预览", description: "按下方选项实时拼接显示。") {
                        MenuBarPreviewPill(model: model)
                    }
                }
            }
            if s[CalendarKeys.menuBarEnabled] {
                DSSection("时间选项") {
                    DSRow("显示时间", description: "在状态栏显示当前时间，可配置图标、24 小时制、上午/下午与精确到秒。") {
                        DSToggle(isOn: s.binding(CalendarKeys.menuBarTime))
                    }
                    if s[CalendarKeys.menuBarTime] {
                        DSRow("显示 icon") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTimeIcon)) }
                        DSRow("使用 24 小时格式") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTime24Hour)) }
                        DSRow("显示上午/下午") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTimePeriod)) }
                        DSRow("时间精确到秒") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTimeSeconds)) }
                    }
                }
                DSSection("日期选项") {
                    DSRow("显示日期", description: "在状态栏显示阳历、农历与星期几。") {
                        DSToggle(isOn: dateEnabled)
                    }
                    if s[CalendarKeys.menuBarDateSection] {
                        DSRow("显示阳历") { DSToggle(isOn: s.binding(CalendarKeys.menuBarDate)) }
                        DSRow("显示农历") { DSToggle(isOn: s.binding(CalendarKeys.menuBarLunar)) }
                        DSRow("显示星期几") { DSToggle(isOn: s.binding(CalendarKeys.menuBarWeekday)) }
                    }
                }
                DSSection("天气选项") {
                    DSRow("显示天气与空气质量", description: "在状态栏显示实时天气温度与空气质量 AQI。") {
                        DSToggle(isOn: weatherEnabled)
                    }
                    if s[CalendarKeys.menuBarWeatherSection] {
                        if s[CalendarKeys.city] == nil {
                            DSRow("天气城市", description: "尚未选择城市，设置后才会显示天气与 AQI。") {
                                Button("前往设置") {
                                    model.context.openSettings(CalendarPlugin.settingsWeatherID)
                                }
                                .buttonStyle(.dsSecondary)
                            }
                        }
                        DSRow("天气") { DSToggle(isOn: s.binding(CalendarKeys.menuBarWeather)) }
                        DSRow("空气质量 AQI") { DSToggle(isOn: aqiEnabled) }
                    }
                }
            }
        }
        .onChange(of: model.needsSecondTick) { model.syncClockTimer() }
    }
}

public struct CalendarAppearanceSettings: View {
    let model: CalendarModel
    let showGlobalAppearanceLink: Bool

    public init(model: CalendarModel, showGlobalAppearanceLink: Bool = true) {
        self.model = model
        self.showGlobalAppearanceLink = showGlobalAppearanceLink
    }

    public var body: some View {
        DSSection("弹出面板样式", footer: "点击状态栏日历时弹出的月历样式，也可以在弹出面板右下角直接切换。「跟随系统」随 macOS 深浅模式切换，「跟随外观」随主应用「外观」设置切换。") {
            DSBlockRow {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(CalendarPopoverStyle.allCases) { style in
                        PopoverStyleCard(
                            style: style,
                            appAppearance: model.appAppearance,
                            selected: model.popoverStyle == style
                        ) {
                            model.popoverStyle = style
                        }
                    }
                }
            }
        }

        if showGlobalAppearanceLink {
            DSSection("主窗口与字体") {
                DSRow("应用外观与字体大小", description: "大窗口月历的日间/夜间主题与全局字号在「设置 → 外观」中统一调整。") {
                    Button("前往「外观」") {
                        model.context.openSettings("appearance")
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        }
    }
}

struct CalendarHolidaySettings: View {
    let model: CalendarModel

    var body: some View {
        DSHolidaySettingsView(workCalendar: model.workCalendar, settings: model.settings)
    }
}

private struct MenuBarPreviewPill: View {
    let model: CalendarModel

    var body: some View {
        CalendarMenuBarPreview(segments: model.menuBarSegments)
            .font(DS.font(13, .medium))
            .monospacedDigit()
            .foregroundStyle(DS.text)
            .padding(.horizontal, 10)
            .frame(height: DS.s(26))
            .background(DS.well, in: .capsule)
            .overlay {
                Capsule().strokeBorder(DS.border)
            }
    }
}

struct WeatherSettings: View {
    let model: CalendarModel
    @State private var query = ""
    @State private var results: [City] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var showQWeatherKey = false

    var body: some View {
        let s = model.settings
        DSSection("城市") {
            DSRow("当前城市", description: s[CalendarKeys.city]?.displayName ?? "还没选") {
                if s[CalendarKeys.city] != nil {
                    Button("刷新天气") { Task { await model.refreshWeather() } }.buttonStyle(.dsSecondary)
                }
            }
            DSRow("搜索城市", description: searchError ?? "输入中文或拼音，比如：深圳、hangzhou。") {
                HStack(spacing: 6) {
                    TextField("", text: $query, prompt: Text("城市名")).textFieldStyle(.ds).frame(width: 200)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        if searching { ProgressView().controlSize(.small).tint(DS.onPrimary) } else { Text("搜索") }
                    }
                    .buttonStyle(.dsPrimary)
                }
            }
            ForEach(results) { city in
                DSRow(city.name, description: city.region) {
                    Button("选这个") {
                        s[CalendarKeys.city] = city
                        results = []
                        query = ""
                        Task { await model.refreshWeather() }
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        }

        DSSection("数据源", footer: "Open-Meteo 免费、无需注册；和风天气的数据更贴近国内天气预报，需要在和风控制台申请密钥和 API Host。") {
            DSRow("天气数据源") {
                DSPicker(
                    selection: s.binding(CalendarKeys.weatherSource),
                    options: WeatherSource.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
            }
            if s[CalendarKeys.weatherSource] == .qweather {
                DSRow("和风密钥 (Key)") {
                    HStack(spacing: 6) {
                        Group {
                            if showQWeatherKey {
                                TextField("", text: s.binding(CalendarKeys.qweatherKey))
                            } else {
                                SecureField("", text: s.binding(CalendarKeys.qweatherKey))
                            }
                        }
                        .textFieldStyle(.ds)
                        .frame(width: 242)
                        Button { showQWeatherKey.toggle() } label: { Image(systemName: showQWeatherKey ? "eye.slash" : "eye") }
                            .buttonStyle(.dsGhost)
                    }
                }
                DSRow("API Host", description: "和风控制台里显示的专属域名。") {
                    TextField("", text: s.binding(CalendarKeys.qweatherHost)).textFieldStyle(.ds).frame(width: 280)
                }
            }
            DSRow("自动刷新间隔") {
                DSStepper(intValue: s.binding(CalendarKeys.refreshMinutes), in: 10...240, step: 10) { "\($0) 分钟" }
            }
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await WeatherService.searchCity(q)
            searchError = results.isEmpty ? "没找到这个城市" : nil
        } catch {
            searchError = error.localizedDescription
        }
    }
}

private struct PopoverStyleCard: View {
    let style: CalendarPopoverStyle
    let appAppearance: AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(height: 76)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? DS.toggle : DS.border, lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 4) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(DS.font(12))
                        .foregroundStyle(selected ? DS.toggle : DS.textTertiary)
                    Text(style.displayName)
                        .font(DS.font(12.5))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch style {
        case .system:
            splitPreview
                .overlay(alignment: .bottomLeading) {
                    PreviewModeBadge(systemImage: "laptopcomputer")
                }
        case .appearance:
            Group {
                switch appAppearance {
                case .light: MiniPopoverPreview(palette: .white)
                case .dark: MiniPopoverPreview(palette: .black)
                case .system: splitPreview
                }
            }
            .overlay(alignment: .bottomLeading) {
                PreviewModeBadge(systemImage: "paintpalette")
            }
        case .white:
            MiniPopoverPreview(palette: .white)
        case .black:
            MiniPopoverPreview(palette: .black)
        case .red:
            MiniPopoverPreview(palette: .red)
        case .blue:
            MiniPopoverPreview(palette: .blue)
        }
    }

    private var splitPreview: some View {
        HStack(spacing: 0) {
            MiniPopoverPreview(palette: .white)
            MiniPopoverPreview(palette: .black)
        }
    }
}

private struct PreviewModeBadge: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(DS.font(9.5, .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 18, height: 18)
            .background(Color.black.opacity(0.62), in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
            }
            .padding(4)
    }
}

private struct MiniPopoverPreview: View {
    let palette: CalendarPopoverPalette

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.headerControlBackground)
                        .frame(width: 14, height: 6)
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.todayButtonBackground)
                        .frame(width: 12, height: 6)
                }
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(palette.headerBackground)

                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.holidayCellBackground).frame(height: 10)
                            .overlay(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 1).fill(palette.holidayBadgeBackground).frame(width: 4, height: 4).padding(1)
                            }
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                    }
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(palette.makeupCellBackground).frame(height: 10)
                            .overlay(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 1).fill(palette.makeupBadgeBackground).frame(width: 4, height: 4).padding(1)
                            }
                    }
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(palette.selectedBorder, lineWidth: 1)
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(palette.dayText.opacity(0.12)).frame(height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.gridBackground)
            }

            if let divider = palette.sidebarDivider {
                Rectangle().fill(divider).frame(width: 0.5)
            }

            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.sidebarText.opacity(0.85))
                    .frame(width: 14, height: 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.daySquareBackground)
                    .frame(width: 14, height: 14)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(palette.sidebarSecondaryText.opacity(0.5))
                    .frame(width: 12, height: 3)
                Spacer(minLength: 0)
            }
            .padding(.top, 7)
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .background(palette.sidebarBackground)
        }
    }
}
