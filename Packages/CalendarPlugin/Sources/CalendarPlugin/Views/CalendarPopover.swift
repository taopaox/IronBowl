import AppKit
import IronBowlKit
import SwiftUI

enum CalendarAssets {
    static let logoImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "CalendarLogo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

/// 菜单栏日历图像渲染器：将各显示段（Logo、天气图标、温度、AQI、日期、星期、农历、时钟图标、时间）
/// 离线绘制为固定高度的 `NSImage`（无全彩 Logo 时为模板图，含全彩 Logo 时按系统浅/深色自适应文字色调），避免 `MenuBarExtra` 动态文本插值在 macOS 上出现截断或消失。
public enum CalendarMenuBarRenderer {
    public static let barHeight: CGFloat = 22

    private enum MeasuredSegment {
        case logo(NSImage, NSSize)
        case symbol(NSImage, NSSize)
        case text(NSAttributedString, NSSize)

        var width: CGFloat {
            switch self {
            case .logo(_, let size): size.width
            case .symbol(_, let size): size.width
            case .text(_, let size): size.width
            }
        }

        var isSymbol: Bool {
            if case .symbol = self { return true }
            return false
        }
    }

    public static func renderImage(
        segments: [MenuBarSegment],
        logoImage: NSImage? = nil,
        isDark: Bool = true,
        scale: CGFloat? = nil
    ) -> NSImage {
        let effective = segments.isEmpty ? [MenuBarSegment.symbol("calendar")] : segments
        let resolvedScale = max(1.0, scale ?? max(2.0, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0))
        let resolvedLogo = logoImage ?? CalendarAssets.logoImage
        let hasColorLogo = effective.contains(.logo) && resolvedLogo != nil
        let fontSize: CGFloat = 13
        let horizontalPadding: CGFloat = 1
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let foregroundColor: NSColor = if hasColorLogo {
            isDark
                ? NSColor(srgbRed: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)
                : NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        } else {
            .black
        }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: fontSize, weight: .medium, scale: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foregroundColor,
        ]

        let measured: [MeasuredSegment] = effective.map { segment in
            switch segment {
            case .logo:
                if let resolvedLogo {
                    let targetHeight: CGFloat = 17
                    let rawSize = resolvedLogo.size
                    let width = (rawSize.height > 0 && rawSize.width > 0)
                        ? ceil(targetHeight * (rawSize.width / rawSize.height))
                        : targetHeight
                    return .logo(resolvedLogo, NSSize(width: width, height: targetHeight))
                }
                let symbol = (NSImage(systemSymbolName: "calendar", accessibilityDescription: nil) ?? NSImage())
                    .withSymbolConfiguration(symbolConfig) ?? NSImage()
                let rawSize = symbol.size
                let size = (rawSize.width > 0 && rawSize.height > 0) ? rawSize : NSSize(width: 14, height: 14)
                return .symbol(symbol, size)
            case .symbol(let name):
                let symbol = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
                    ?? NSImage())
                    .withSymbolConfiguration(symbolConfig) ?? NSImage()
                let rawSize = symbol.size
                let size = (rawSize.width > 0 && rawSize.height > 0) ? rawSize : NSSize(width: 14, height: 14)
                return .symbol(symbol, size)
            case .text(let value):
                let attr = NSAttributedString(string: value, attributes: textAttributes)
                let size = attr.size()
                return .text(attr, NSSize(width: ceil(size.width), height: size.height))
            }
        }

        var contentWidth: CGFloat = 0
        for (index, item) in measured.enumerated() {
            if index > 0 {
                contentWidth += gap(after: measured[index - 1], before: item)
            }
            contentWidth += item.width
        }

        let totalWidth = max(18, ceil(contentWidth + horizontalPadding * 2))
        let logicalSize = NSSize(width: totalWidth, height: barHeight)
        let pixelWidth = max(1, Int(ceil(logicalSize.width * resolvedScale)))
        let pixelHeight = max(1, Int(ceil(logicalSize.height * resolvedScale)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let fallback = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        rep.size = logicalSize

        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            ctx.cgContext.setShouldAntialias(true)
            ctx.cgContext.setAllowsAntialiasing(true)
            ctx.cgContext.setShouldSmoothFonts(false)

            var x = horizontalPadding
            for (index, item) in measured.enumerated() {
                if index > 0 {
                    x += gap(after: measured[index - 1], before: item)
                }
                switch item {
                case .logo(let logo, let size):
                    let y = ((barHeight - size.height) / 2).rounded(.toNearestOrAwayFromZero)
                    logo.draw(
                        in: NSRect(x: x, y: y, width: size.width, height: size.height),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                    x += size.width
                case .symbol(let symbolImage, let size):
                    let y = ((barHeight - size.height) / 2).rounded(.toNearestOrAwayFromZero)
                    symbolImage.draw(
                        in: NSRect(x: x, y: y, width: size.width, height: size.height),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                    x += size.width
                case .text(let attr, let size):
                    let y = (barHeight - size.height) / 2
                    attr.draw(at: NSPoint(x: x, y: y))
                    x += size.width
                }
            }
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: logicalSize)
        image.addRepresentation(rep)
        image.isTemplate = !hasColorLogo
        return image
    }

    private static func gap(after previous: MeasuredSegment, before next: MeasuredSegment) -> CGFloat {
        (previous.isSymbol && !next.isSymbol) ? 3 : 5
    }
}

/// 菜单栏日历的标签：通过离线图像稳定渲染 Logo + 天气图标/温度/AQI + 日期/星期/农历 + 时间图标/时间。
public struct CalendarMenuBarLabel: View {
    let model: CalendarModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: CalendarModel) { self.model = model }

    public var body: some View {
        let isDark = (model.appAppearance == .system ? colorScheme : model.systemColorScheme) == .dark
        Image(nsImage: CalendarMenuBarRenderer.renderImage(segments: model.menuBarSegments, isDark: isDark))
            .onAppear { model.syncClockTimer() }
            .onChange(of: model.needsSecondTick) { model.syncClockTimer() }
    }
}

/// 设置页里的状态栏日历预览视图（按全局字体缩放渲染）。
public struct CalendarMenuBarPreview: View {
    let segments: [MenuBarSegment]

    public init(segments: [MenuBarSegment]) {
        self.segments = segments
    }

    public var body: some View {
        let effective = segments.isEmpty ? [MenuBarSegment.symbol("calendar")] : segments
        HStack(spacing: 4) {
            ForEach(Array(effective.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .logo:
                    if let logo = CalendarAssets.logoImage {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: DS.s(17), height: DS.s(17))
                    } else {
                        Image(systemName: "calendar")
                    }
                case .symbol(let name):
                    Image(systemName: name)
                case .text(let value):
                    Text(verbatim: value)
                }
            }
        }
    }
}

private enum PopoverActiveMenu: Equatable {
    case year, month, style
}

/// 点菜单栏日历弹出的面板：左边月历，右边时间、日期块、天气、农历，支持多种主题样式。
public struct CalendarPopover: View {
    let model: CalendarModel
    let onQuit: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeMenu: PopoverActiveMenu?

    public init(model: CalendarModel, onQuit: (() -> Void)? = nil) {
        self.model = model
        self.onQuit = onQuit
    }

    public var body: some View {
        let effectiveSystemColorScheme = model.appAppearance == .system ? colorScheme : model.systemColorScheme
        let palette = model.popoverStyle.palette(
            appAppearance: model.appAppearance,
            systemColorScheme: effectiveSystemColorScheme
        )
        HStack(spacing: 0) {
            PopoverMonthPane(model: model, palette: palette, activeMenu: $activeMenu, onQuit: onQuit)
                .frame(width: DS.s(388))
            if let divider = palette.sidebarDivider {
                Rectangle().fill(divider).frame(width: 1)
            }
            PopoverSidePanel(model: model, palette: palette, activeMenu: $activeMenu)
                .frame(width: DS.s(152))
        }
        .background(palette.gridBackground)
        .overlay {
            if activeMenu != nil {
                Color.black.opacity(0.001)
                    .contentShape(.rect)
                    .onTapGesture { activeMenu = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if activeMenu == .year {
                PopoverYearDropdown(model: model, palette: palette) {
                    activeMenu = nil
                }
                .padding(.top, DS.s(40))
                .padding(.leading, 12)
            } else if activeMenu == .month {
                PopoverMonthDropdown(model: model, palette: palette) {
                    activeMenu = nil
                }
                .padding(.top, DS.s(40))
                .padding(.leading, DS.s(122))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if activeMenu == .style {
                PopoverStyleDropdown(model: model, palette: palette) {
                    activeMenu = nil
                }
                .padding(.bottom, DS.s(38))
                .padding(.trailing, 10)
            }
        }
        .onAppear {
            activeMenu = nil
            model.refreshSystemColorScheme()
            model.goToday()
        }
        .onDisappear {
            activeMenu = nil
        }
    }
}

// MARK: - 左侧月历区

private struct PopoverMonthPane: View {
    let model: CalendarModel
    let palette: CalendarPopoverPalette
    @Binding var activeMenu: PopoverActiveMenu?
    let onQuit: (() -> Void)?
    @Environment(\.dismissMenuBarPopover) private var dismissMenuBarPopover
    @State private var hoveringYear = false
    @State private var hoveringMonth = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            weekdayBar
            dateGrid
            footerBar
        }
        .background(palette.gridBackground)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                activeMenu = activeMenu == .year ? nil : .year
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: String(model.year))
                        .font(DS.font(13.5, .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    Image(systemName: activeMenu == .year ? "chevron.up" : "chevron.down")
                        .font(DS.font(10, .semibold))
                        .opacity(0.85)
                }
                .foregroundStyle(palette.headerText)
                .padding(.horizontal, 10)
                .frame(height: DS.s(26))
                .background(
                    (activeMenu == .year || hoveringYear) ? palette.headerHoverBackground : palette.headerControlBackground,
                    in: .rect(cornerRadius: 6)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(palette.headerControlBorder, lineWidth: 1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hoveringYear = $0 }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                PopoverHeaderIconButton(systemImage: "chevron.left", palette: palette) {
                    activeMenu = nil
                    model.shiftMonth(-1)
                }

                Button {
                    activeMenu = activeMenu == .month ? nil : .month
                } label: {
                    Text(String(format: "%02d月", model.monthNumber))
                        .font(DS.font(14.5, .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(palette.headerText)
                        .padding(.horizontal, 8)
                        .frame(height: DS.s(26))
                        .background(
                            (activeMenu == .month || hoveringMonth) ? palette.headerHoverBackground : .clear,
                            in: .rect(cornerRadius: 6)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .onHover { hoveringMonth = $0 }

                PopoverHeaderIconButton(systemImage: "chevron.right", palette: palette) {
                    activeMenu = nil
                    model.shiftMonth(1)
                }
            }
            .fixedSize()

            Spacer(minLength: 4)

            Button {
                activeMenu = nil
                model.goToday()
            } label: {
                Text("返回今天")
                    .font(DS.font(12.5, .medium))
                    .lineLimit(1)
                    .foregroundStyle(palette.todayButtonText)
                    .padding(.horizontal, 10)
                    .frame(height: DS.s(26))
                    .background(palette.todayButtonBackground, in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.todayButtonBorder, lineWidth: 1)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: DS.s(44))
        .background(palette.headerBackground)
    }

    private var weekdayBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, w in
                Text("周" + w.text)
                    .font(DS.font(12, .medium))
                    .foregroundStyle(w.weekend ? palette.weekdayWeekendText : palette.weekdayText)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: DS.s(28))
        .background(palette.weekdayBarBackground)
    }

    private var dateGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
            ForEach(model.cells) { cell in
                PopoverDayCell(model: model, cell: cell, palette: palette)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(palette.gridBackground)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(model.countdownText(for: model.selected))
                .font(DS.font(11.5))
                .foregroundStyle(palette.footerText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onQuit {
                Text(Bundle.main.displayVersion)
                    .font(DS.font(11))
                    .monospacedDigit()
                    .foregroundStyle(palette.footerText.opacity(0.75))
                    .help("饭碗万年历 \(Bundle.main.fullVersion)")
                PopoverFooterQuitButton(palette: palette) {
                    activeMenu = nil
                    dismissMenuBarPopover()
                    onQuit()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: DS.s(28))
        .background(palette.gridBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.gridBorder).frame(height: 1)
        }
    }
}

private struct PopoverHeaderIconButton: View {
    let systemImage: String
    let palette: CalendarPopoverPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.font(12.5, .semibold))
                .foregroundStyle(palette.headerText)
                .frame(width: DS.s(26), height: DS.s(26))
                .background(hovering ? palette.headerHoverBackground : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverFooterQuitButton: View {
    let palette: CalendarPopoverPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("退出万年历")
                .font(DS.font(11.5))
                .foregroundStyle(palette.footerText)
                .padding(.horizontal, 7)
                .frame(height: DS.s(20))
                .background(hovering ? palette.hoverBackground : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverDayCell: View {
    let model: CalendarModel
    let cell: DayCell
    let palette: CalendarPopoverPalette
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
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: cell.date))")
                    .font(DS.font(16, isToday ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(red ? palette.weekendDayText : palette.dayText)
                Text(label.text)
                    .font(DS.font(10, label.isSpecial ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(label.isSpecial ? palette.specialLunarText : palette.lunarText)
            }
            .opacity(cell.inMonth ? 1 : 0.35)
            .frame(maxWidth: .infinity)
            .frame(height: DS.s(46))
            .background(cellBackground(kind: info.kind, inMonth: cell.inMonth), in: .rect(cornerRadius: 6))
            .overlay {
                if hovering {
                    RoundedRectangle(cornerRadius: 6).fill(palette.hoverBackground)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(palette.selectedBorder, lineWidth: 1.5)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(palette.todayBorder.opacity(0.65), lineWidth: 1)
                }
            }
            .overlay(alignment: .topLeading) {
                if let badge {
                    let isHoliday = badge == "休"
                    Text(badge)
                        .font(DS.font(9.5, .bold))
                        .foregroundStyle(isHoliday ? palette.holidayBadgeText : palette.makeupBadgeText)
                        .frame(width: DS.s(15), height: DS.s(15))
                        .background(isHoliday ? palette.holidayBadgeBackground : palette.makeupBadgeBackground, in: .rect(cornerRadius: 3))
                        .opacity(cell.inMonth ? 1 : 0.85)
                        .padding(2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isToday {
                    Text("今")
                        .font(DS.font(9.5, .bold))
                        .foregroundStyle(palette.todayBadgeText)
                        .frame(width: DS.s(15), height: DS.s(15))
                        .background(palette.todayBadgeBackground, in: .rect(cornerRadius: 3))
                        .padding(2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func cellBackground(kind: DayInfo.Kind, inMonth: Bool) -> Color {
        switch kind {
        case .holiday:
            palette.holidayCellBackground.opacity(inMonth ? 1 : 0.72)
        case .makeupWorkday:
            palette.makeupCellBackground.opacity(inMonth ? 1 : 0.72)
        default:
            .clear
        }
    }
}

// MARK: - 右侧详情栏

private struct PopoverSidePanel: View {
    let model: CalendarModel
    let palette: CalendarPopoverPalette
    @Binding var activeMenu: PopoverActiveMenu?
    @Environment(\.dismissMenuBarPopover) private var dismissMenuBarPopover

    private func runAndDismiss(_ action: () -> Void) {
        activeMenu = nil
        dismissMenuBarPopover()
        action()
    }

    var body: some View {
        let d = model.selected
        let l = Lunar.lunar(d)
        let extra = [Lunar.festival(d), Lunar.solarTerm(d)].compactMap { $0 }
        VStack(spacing: 8) {
            Text(CN.time(model.now))
                .font(DS.font(30, .light))
                .monospacedDigit()
                .foregroundStyle(palette.sidebarText)
                .padding(.top, 8)
            Text(CN.weekday(d))
                .font(DS.font(13.5, .medium))
                .foregroundStyle(palette.sidebarText)
            Text("\(CalendarModel.cal.component(.day, from: d))")
                .font(DS.font(36, .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.daySquareText)
                .frame(width: DS.s(70), height: DS.s(70))
                .background(palette.daySquareBackground, in: .rect(cornerRadius: 10))
                .padding(.vertical, 2)

            weather

            Rectangle()
                .fill(palette.sidebarDividerLine)
                .frame(height: 1)
                .padding(.horizontal, 14)

            VStack(spacing: 4) {
                Text("\(l.ganzhiYear)【\(l.zodiac)年】")
                    .font(DS.font(12, .medium))
                    .foregroundStyle(palette.sidebarText)
                Text(l.text)
                    .font(DS.font(13.5, .medium))
                    .foregroundStyle(palette.sidebarText)
                ForEach(extra, id: \.self) { item in
                    PopoverSidebarPill(text: item, background: palette.sidebarPillBackground, foreground: palette.sidebarPillText)
                }
                if let badge = model.dayBadge(d) {
                    let isHoliday = badge == "休"
                    PopoverSidebarPill(
                        text: isHoliday ? "放假" : "调休上班",
                        background: isHoliday ? palette.sidebarHolidayPillBackground : palette.sidebarMakeupPillBackground,
                        foreground: isHoliday ? palette.sidebarHolidayPillText : palette.sidebarMakeupPillText
                    )
                }
            }

            Spacer(minLength: 0)

            PopoverCityButton(
                title: model.weather?.city ?? model.settings[CalendarKeys.city]?.name ?? "设置城市",
                palette: palette
            ) {
                runAndDismiss {
                    model.context.openSettings(CalendarPlugin.settingsWeatherID)
                }
            }

            HStack(spacing: 6) {
                PopoverSideIconButton(
                    systemImage: "paintpalette",
                    palette: palette,
                    active: activeMenu == .style
                ) {
                    activeMenu = activeMenu == .style ? nil : .style
                }
                .help("弹出样式")

                PopoverSideIconButton(systemImage: "arrow.up.left.and.arrow.down.right", palette: palette) {
                    runAndDismiss {
                        model.context.openPlugin(CalendarPlugin.pluginID)
                    }
                }
                .help("打开大窗口")

                PopoverSideIconButton(systemImage: "gearshape", palette: palette) {
                    runAndDismiss {
                        model.context.openSettings(CalendarPlugin.settingsDisplayID)
                    }
                }
                .help("日历设置")
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 6)
        .background(palette.sidebarBackground)
    }

    @ViewBuilder
    private var weather: some View {
        if let w = model.weather(on: model.selected) {
            VStack(spacing: 2) {
                Image(systemName: w.symbol)
                    .font(DS.font(20))
                    .foregroundStyle(palette.sidebarText)
                Text("\(Int(w.low.rounded()))° ~ \(Int(w.high.rounded()))°")
                    .font(DS.caption)
                    .monospacedDigit()
                    .foregroundStyle(palette.sidebarText)
                Text(w.text)
                    .font(DS.caption)
                    .foregroundStyle(palette.sidebarSecondaryText)
            }
        } else if model.weather == nil {
            VStack(spacing: 2) {
                Text("N/A")
                    .font(DS.font(19, .medium))
                    .foregroundStyle(palette.sidebarSecondaryText)
                Text("暂无数据")
                    .font(DS.font(11))
                    .foregroundStyle(palette.sidebarTertiaryText)
            }
        } else {
            Text("暂无预报")
                .font(DS.caption)
                .foregroundStyle(palette.sidebarTertiaryText)
        }
    }
}

// MARK: - 面板内下拉浮层

private struct PopoverYearDropdown: View {
    let model: CalendarModel
    let palette: CalendarPopoverPalette
    let onDismiss: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(1990...2050, id: \.self) { year in
                        PopoverDropdownRow(
                            title: "\(String(year))年",
                            selected: year == model.year,
                            palette: palette
                        ) {
                            model.go(year: year)
                            onDismiss()
                        }
                        .id(year)
                    }
                }
                .padding(6)
            }
            .onAppear {
                proxy.scrollTo(model.year, anchor: .center)
            }
        }
        .frame(width: DS.s(108), height: DS.s(204))
        .background(palette.dropdownBackground, in: .rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(palette.dropdownBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(palette.usesDarkGrid ? 0.45 : 0.14), radius: 12, y: 5)
    }
}

private struct PopoverMonthDropdown: View {
    let model: CalendarModel
    let palette: CalendarPopoverPalette
    let onDismiss: () -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(1...12, id: \.self) { month in
                PopoverMonthTile(
                    title: "\(month)月",
                    selected: month == model.monthNumber,
                    palette: palette
                ) {
                    model.go(month: month)
                    onDismiss()
                }
            }
        }
        .padding(6)
        .frame(width: DS.s(176))
        .background(palette.dropdownBackground, in: .rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(palette.dropdownBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(palette.usesDarkGrid ? 0.45 : 0.14), radius: 12, y: 5)
    }
}

private struct PopoverMonthTile: View {
    let title: String
    let selected: Bool
    let palette: CalendarPopoverPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(DS.font(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.dropdownSelectedText : palette.dropdownText)
                    .lineLimit(1)
                if selected {
                    Image(systemName: "checkmark")
                        .font(DS.font(9.5, .bold))
                        .foregroundStyle(palette.dropdownCheckmark)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: DS.s(28))
            .background(
                selected ? palette.dropdownSelectedBackground : (hovering ? palette.dropdownHoverBackground : .clear),
                in: .rect(cornerRadius: DS.controlRadius)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverStyleDropdown: View {
    let model: CalendarModel
    let palette: CalendarPopoverPalette
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(CalendarPopoverStyle.allCases) { style in
                PopoverDropdownRow(
                    title: style.displayName,
                    selected: model.popoverStyle == style,
                    palette: palette,
                    leading: {
                        StyleSwatchDot(
                            style: style,
                            appAppearance: model.appAppearance,
                            borderColor: palette.dropdownText.opacity(0.24)
                        )
                    }
                ) {
                    model.popoverStyle = style
                    onDismiss()
                }
            }
        }
        .padding(6)
        .frame(width: DS.s(138))
        .background(palette.dropdownBackground, in: .rect(cornerRadius: DS.radius))
        .overlay {
            RoundedRectangle(cornerRadius: DS.radius)
                .strokeBorder(palette.dropdownBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(palette.usesDarkGrid ? 0.45 : 0.14), radius: 12, y: 5)
    }
}

private struct StyleSwatchDot: View {
    let style: CalendarPopoverStyle
    let appAppearance: AppearanceMode
    let borderColor: Color

    var body: some View {
        Group {
            switch style {
            case .system:
                splitDot
            case .appearance:
                ZStack {
                    appearanceBase
                    Circle()
                        .fill(CalendarPopoverPalette.white.daySquareBackground)
                        .frame(width: 4, height: 4)
                }
            case .white:
                Color.white
            case .black:
                Color(white: 0.14)
            case .red:
                CalendarPopoverPalette.red.headerBackground
            case .blue:
                CalendarPopoverPalette.blue.headerBackground
            }
        }
        .frame(width: 10, height: 10)
        .clipShape(.circle)
        .overlay {
            Circle().strokeBorder(borderColor, lineWidth: 0.5)
        }
    }

    private var splitDot: some View {
        HStack(spacing: 0) {
            Color.white
            Color(white: 0.15)
        }
    }

    @ViewBuilder
    private var appearanceBase: some View {
        switch appAppearance {
        case .light: Color.white
        case .dark: Color(white: 0.14)
        case .system: splitDot
        }
    }
}

private struct PopoverDropdownRow<Leading: View>: View {
    let title: String
    let selected: Bool
    let palette: CalendarPopoverPalette
    @ViewBuilder var leading: Leading
    let action: () -> Void
    @State private var hovering = false

    init(
        title: String,
        selected: Bool,
        palette: CalendarPopoverPalette,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        action: @escaping () -> Void
    ) {
        self.title = title
        self.selected = selected
        self.palette = palette
        self.leading = leading()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                leading
                Text(verbatim: title)
                    .font(DS.font(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.dropdownSelectedText : palette.dropdownText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(DS.font(11, .semibold))
                        .foregroundStyle(palette.dropdownCheckmark)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DS.s(28))
            .background(
                selected ? palette.dropdownSelectedBackground : (hovering ? palette.dropdownHoverBackground : .clear),
                in: .rect(cornerRadius: DS.controlRadius)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverSidebarPill: View {
    let text: String
    let background: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(DS.font(11, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: .capsule)
    }
}

private struct PopoverCityButton: View {
    let title: String
    let palette: CalendarPopoverPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "location.fill")
                .font(DS.font(12, .medium))
                .foregroundStyle(palette.sidebarText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: DS.s(26))
                .background(hovering ? palette.sidebarHoverBackground : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PopoverSideIconButton: View {
    let systemImage: String
    let palette: CalendarPopoverPalette
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.font(13.5))
                .foregroundStyle(active ? palette.sidebarText : palette.sidebarSecondaryText)
                .frame(width: DS.s(26), height: DS.s(26))
                .background((active || hovering) ? palette.sidebarHoverBackground : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
