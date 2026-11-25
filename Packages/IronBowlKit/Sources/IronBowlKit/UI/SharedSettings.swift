import AppKit
import SwiftUI

public nonisolated enum AppearanceMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "日间"
        case .dark: "夜间"
        }
    }
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 工作台与独立版万年历共用的外观、字体设置键。
public enum AppSharedKeys {
    public static let appearance = SettingKey<AppearanceMode>("app.appearance", default: .system)
    public static let fontScale = SettingKey<Double>("app.fontScale", default: 1.0)
    public static let fontScales: [Double] = [0.9, 1.0, 1.1, 1.2, 1.3, 1.4]
}

/// 共享的外观设置（主题 + 字体大小），主应用和独立万年历共用。
public struct DSAppearanceSettingsView: View {
    let settings: SettingsStore
    let onAppearanceChange: () -> Void
    let onFontScaleChange: () -> Void

    public init(
        settings: SettingsStore,
        onAppearanceChange: @escaping () -> Void = {},
        onFontScaleChange: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.onAppearanceChange = onAppearanceChange
        self.onFontScaleChange = onFontScaleChange
    }

    public var body: some View {
        let currentMode = settings[AppSharedKeys.appearance]
        DSSection("主题", footer: "主窗口、设置、菜单栏面板和提醒卡片都会一起切换。") {
            DSBlockRow {
                HStack(spacing: 14) {
                    ForEach(AppearanceMode.allCases) { mode in
                        ThemeCard(mode: mode, selected: currentMode == mode) {
                            settings[AppSharedKeys.appearance] = mode
                            onAppearanceChange()
                        }
                    }
                }
            }
        }
        DSSection("文字") {
            DSRow("字体大小", description: "所有界面的文字和控件一起缩放，松手后生效。") {
                FontScaleSlider(settings: settings, onFontScaleChange: onFontScaleChange)
            }
        }
    }
}

/// 字体大小滑块：小 · 默认 · 大，拖动松手后才应用（应用时界面会重建）。
private struct FontScaleSlider: View {
    let settings: SettingsStore
    let onFontScaleChange: () -> Void
    @State private var index: Double = 1

    var body: some View {
        let scales = AppSharedKeys.fontScales
        let currentScale = settings[AppSharedKeys.fontScale]
        VStack(spacing: 4) {
            Slider(value: $index, in: 0...Double(scales.count - 1), step: 1) { editing in
                if !editing {
                    let scale = scales[Int(index)]
                    DS.fontScale = scale
                    settings[AppSharedKeys.fontScale] = scale
                    onFontScaleChange()
                }
            }
            .tint(DS.primaryFill)
            // 「默认」对准第 2 档刻度：滑块两端各留约 10pt。
            ZStack(alignment: .leading) {
                Text("小")
                Text("默认").fixedSize().position(x: 10 + (300 - 20) / Double(scales.count - 1), y: 8)
                Text("大").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 16)
            .font(DS.caption)
            .foregroundStyle(DS.textSecondary)
        }
        .frame(width: 300)
        .onAppear { index = Double(scales.firstIndex(of: currentScale) ?? 1) }
        .onChange(of: currentScale) { _, newValue in
            index = Double(scales.firstIndex(of: newValue) ?? 1)
        }
    }
}

/// 主题选择卡：上面是缩略预览，下面是名字。
private struct ThemeCard: View {
    let mode: AppearanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 84)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? DS.toggle : DS.border, lineWidth: selected ? 2 : 1)
                    }
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? DS.toggle : DS.textTertiary)
                    Text(mode.displayName).font(DS.body)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
            }
        }
    }
}

/// 缩略窗口：侧栏 + 内容 + 几条线。用固定颜色，不受当前外观影响。
private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let side = dark ? Color(white: 0.11) : Color(white: 0.965)
        let main = dark ? Color(white: 0.08) : .white
        let line = dark ? Color(white: 0.28) : Color(white: 0.86)
        let ink = dark ? Color(white: 0.92) : Color(white: 0.1)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i == 0 ? line : line.opacity(0.6)).frame(height: 5)
                }
                Spacer()
            }
            .padding(7)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .background(side)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 34, height: 6)
                RoundedRectangle(cornerRadius: 4).stroke(line).frame(height: 20)
                RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 50, height: 5)
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(main)
        }
    }
}

/// 共享的法定节假日与手动调休设置，工作台和独立版万年历共用。
public struct DSHolidaySettingsView: View {
    let workCalendar: WorkCalendar
    let settings: SettingsStore
    @State private var markDate = Date()

    public init(workCalendar: WorkCalendar, settings: SettingsStore) {
        self.workCalendar = workCalendar
        self.settings = settings
    }

    public var body: some View {
        DSSection("法定节假日与调休", footer: "holiday-cn 根据国务院放假通知自动更新，免费、无需注册。手动标记优先于联网数据。") {
            DSRow("数据源") {
                DSPicker(
                    selection: settings.binding(WorkCalendar.sourceKey),
                    options: HolidaySource.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
            }
            DSRow("更新频率") {
                DSPicker(
                    selection: settings.binding(WorkCalendar.frequencyKey),
                    options: HolidayUpdateFrequency.allCases.map { DSPickerOption($0, title: $0.displayName, subtitle: $0.detail) }
                )
            }
            DSRow("已缓存数据", description: cachedText) {
                Button {
                    Task { await workCalendar.updateNow() }
                } label: {
                    if workCalendar.isUpdating { ProgressView().controlSize(.small) } else { Text("立即更新") }
                }
                .buttonStyle(.dsSecondary)
                .disabled(settings[WorkCalendar.sourceKey] == .manual)
            }
        }

        DSSection("手动标记某一天") {
            DSRow("日期", description: label(workCalendar.dayInfo(markDate)) + (workCalendar.override(for: markDate) != nil ? "（手动标记）" : "")) {
                DatePicker("", selection: $markDate, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
            }
            DSBlockRow {
                HStack(spacing: 8) {
                    Button("标为放假") { workCalendar.setOverride(markDate, isOffDay: true, note: "手动放假") }.buttonStyle(.dsSecondary)
                    Button("标为上班") { workCalendar.setOverride(markDate, isOffDay: false, note: "手动补班") }.buttonStyle(.dsSecondary)
                    Button("清除手动标记") { workCalendar.setOverride(markDate, isOffDay: nil) }.buttonStyle(.dsGhost)
                        .disabled(workCalendar.override(for: markDate) == nil)
                }
            }
        }
    }

    private var cachedText: String {
        var t = workCalendar.cachedYears.isEmpty ? "还没有节假日数据" : "已缓存 \(workCalendar.cachedYears.map(String.init).joined(separator: "、")) 年"
        if let last = settings[WorkCalendar.lastFetchKey] { t += "，更新于 \(CN.dateTime(last))" }
        if let e = workCalendar.lastError { t += "。\(e)" }
        return t
    }

    private func label(_ info: DayInfo) -> String {
        switch info.kind {
        case .workday: "工作日"
        case .makeupWorkday: "调休上班" + (info.name.map { "（\($0)）" } ?? "")
        case .weekend: "休息日"
        case .holiday: "放假" + (info.name.map { "（\($0)）" } ?? "")
        }
    }
}
