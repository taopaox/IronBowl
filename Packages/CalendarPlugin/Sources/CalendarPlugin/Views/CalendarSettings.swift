import IronBowlKit
import SwiftUI

struct CalendarDisplaySettings: View {
    let model: CalendarModel

    var body: some View {
        let s = model.settings
        DSSection("月历", footer: "每周第一天与时间制式会同步作用于主窗口月历、状态栏日历与弹出面板；节假日与调休数据可在左侧「节假日」中管理。") {
            DSRow("每周第一天") {
                DSPicker(
                    selection: s.binding(CalendarKeys.firstWeekday),
                    options: [
                        DSPickerOption(2, title: "周一", subtitle: "按国内习惯，周一排在月历第一列。"),
                        DSPickerOption(1, title: "周日", subtitle: "按国际习惯，周日排在月历第一列。"),
                    ]
                )
            }
            DSRow("时间制式", description: "切换 12 小时制或 24 小时制显示。") {
                CalendarTimeFormatPicker(selection: s.binding(CalendarKeys.menuBarTime24Hour))
            }
        }
    }
}

private struct CalendarTimeFormatPicker: View {
    @Binding var selection: Bool

    var body: some View {
        DSPicker(
            selection: $selection,
            options: [
                DSPickerOption(true, title: "24 小时制", subtitle: "例如 18:30"),
                DSPickerOption(false, title: "12 小时制", subtitle: "例如 下午 6:30"),
            ]
        )
    }
}

private enum StylePreviewBackdrop: String, CaseIterable, Identifiable {
    case auto, dark, light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "跟随"
        case .dark: "深色"
        case .light: "浅色"
        }
    }
}

struct CalendarStatusBarSettings: View {
    let model: CalendarModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedCategory: CalendarMenuBarStyleCategory?
    @State private var previewBackdrop: StylePreviewBackdrop = .auto

    private var s: SettingsStore { model.settings }

    private var effectivePreviewIsDark: Bool {
        switch previewBackdrop {
        case .auto: (model.appAppearance == .system ? colorScheme : model.systemColorScheme) == .dark
        case .dark: true
        case .light: false
        }
    }

    private var filteredStyles: [CalendarMenuBarStyle] {
        guard let selectedCategory else { return CalendarMenuBarStyle.allCases }
        return CalendarMenuBarStyle.allCases.filter { $0.category == selectedCategory }
    }

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
                if model.isStandaloneCalendarRunning {
                    DSBlockRow {
                        DSBanner(.info, "检测到独立版「饭碗万年历」正在运行，主工作台已自动隐藏内置状态栏日历以避免重复显示；退出独立版后会自动恢复。")
                    }
                }
                if s[CalendarKeys.menuBarEnabled] {
                    DSRow("当前预览", description: "当前风格：#\(model.menuBarStyle.code) \(model.menuBarStyle.displayName)") {
                        MenuBarPreviewPill(model: model, isDark: effectivePreviewIsDark)
                    }
                    DSRow("显示 Logo", description: "在状态栏日历最左侧显示万年历图标。") {
                        DSToggle(isOn: s.binding(CalendarKeys.menuBarLogo))
                    }
                }
            }
            if s[CalendarKeys.menuBarEnabled] {
                DSSection("状态栏风格", footer: "内置 20 套状态栏视觉风格，点击即可实时切换顶部状态栏外观，所有样式均自动适配深浅模式与下方显示选项。") {
                    DSBlockRow {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 6) {
                                StyleFilterChip(title: "全部 (20)", selected: selectedCategory == nil) {
                                    selectedCategory = nil
                                }
                                ForEach(CalendarMenuBarStyleCategory.allCases) { category in
                                    StyleFilterChip(title: category.displayName, selected: selectedCategory == category) {
                                        selectedCategory = category
                                    }
                                }
                                Spacer(minLength: 4)
                                HStack(spacing: 2) {
                                    ForEach(StylePreviewBackdrop.allCases) { mode in
                                        Button {
                                            previewBackdrop = mode
                                        } label: {
                                            Text(mode.title)
                                                .font(DS.font(11, previewBackdrop == mode ? .semibold : .regular))
                                                .foregroundStyle(previewBackdrop == mode ? DS.text : DS.textTertiary)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(
                                                    previewBackdrop == mode ? DS.card : .clear,
                                                    in: .rect(cornerRadius: 5)
                                                )
                                                .contentShape(.rect)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(2)
                                .background(DS.well, in: .rect(cornerRadius: 7))
                            }

                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(filteredStyles) { style in
                                    MenuBarStyleCard(
                                        style: style,
                                        snapshot: model.menuBarSnapshot,
                                        isDark: effectivePreviewIsDark,
                                        selected: model.menuBarStyle == style
                                    ) {
                                        model.menuBarStyle = style
                                    }
                                }
                            }
                        }
                    }
                }
                DSSection("时间选项") {
                    DSRow("显示时间", description: "在状态栏显示当前时间，可配置图标、12/24 小时制、上午/下午与精确到秒。") {
                        DSToggle(isOn: s.binding(CalendarKeys.menuBarTime))
                    }
                    if s[CalendarKeys.menuBarTime] {
                        DSRow("显示 icon") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTimeIcon)) }
                        DSRow("时间制式", description: "同步作用于状态栏时间、弹出面板时钟与天气更新时间。") {
                            CalendarTimeFormatPicker(selection: s.binding(CalendarKeys.menuBarTime24Hour))
                        }
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
                        DSRow("显示休/班角标", description: "法定节假日与调休补班日显示「休」「班」标识。") {
                            DSToggle(isOn: s.binding(CalendarKeys.menuBarHolidayBadge))
                        }
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
    let isDark: Bool

    var body: some View {
        let image = CalendarMenuBarRenderer.renderImage(
            snapshot: model.menuBarSnapshot,
            style: model.menuBarStyle,
            isDark: isDark,
            scale: 2.0
        )
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: CalendarMenuBarRenderer.barHeight)
            .foregroundStyle(isDark ? Color.white : Color.black)
            .padding(.horizontal, 10)
            .frame(height: DS.s(28))
            .background(isDark ? Color(white: 0.12) : Color(white: 0.94), in: .capsule)
            .overlay {
                Capsule().strokeBorder(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10))
            }
            .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

private struct StyleFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.font(11.5, selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.onPrimary : DS.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? DS.toggle : DS.well, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarStyleCard: View {
    let style: CalendarMenuBarStyle
    let snapshot: CalendarMenuBarSnapshot
    let isDark: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let rendered = CalendarMenuBarRenderer.renderImage(
            snapshot: snapshot,
            style: style,
            isDark: isDark,
            scale: 2.0
        )
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(nsImage: rendered)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: CalendarMenuBarRenderer.barHeight)
                        .foregroundStyle(isDark ? Color.white : Color.black)
                        .environment(\.colorScheme, isDark ? .dark : .light)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: DS.s(36))
                .background(
                    isDark
                        ? Color(red: 0.09, green: 0.11, blue: 0.15)
                        : Color(red: 0.92, green: 0.93, blue: 0.96),
                    in: .rect(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08), lineWidth: 0.5)
                }

                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(DS.font(12))
                        .foregroundStyle(selected ? DS.toggle : DS.textTertiary)
                    Text("#\(style.code)")
                        .font(DS.font(10.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? DS.toggle : DS.textTertiary)
                    Text(style.displayName)
                        .font(DS.font(12.5, selected ? .semibold : .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(style.category.displayName)
                        .font(DS.font(10))
                        .foregroundStyle(DS.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(DS.well, in: .capsule)
                }

                Text(style.subtitle)
                    .font(DS.font(10.5))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? DS.hover : DS.card, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? DS.toggle : DS.border, lineWidth: selected ? 1.8 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
