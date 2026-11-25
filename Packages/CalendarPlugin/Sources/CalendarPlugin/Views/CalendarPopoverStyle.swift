import IronBowlKit
import SwiftUI

/// 菜单栏日历弹出面板的显示样式。
public nonisolated enum CalendarPopoverStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, appearance, white, black, red, blue

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .appearance: "跟随外观"
        case .white: "简约白"
        case .black: "深邃黑"
        case .red: "经典红"
        case .blue: "经典蓝"
        }
    }

    /// 根据主应用外观设置和 macOS 系统深浅外观，解析出对应的固定 sRGB 调色板。
    public func palette(
        appAppearance: AppearanceMode,
        systemColorScheme: ColorScheme
    ) -> CalendarPopoverPalette {
        switch self {
        case .system:
            systemColorScheme == .dark ? .black : .white
        case .appearance:
            switch appAppearance {
            case .light: .white
            case .dark: .black
            case .system: systemColorScheme == .dark ? .black : .white
            }
        case .white:
            .white
        case .black:
            .black
        case .red:
            .red
        case .blue:
            .blue
        }
    }
}

private nonisolated func srgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
    Color(
        .sRGB,
        red: Double((hex >> 16) & 0xFF) / 255.0,
        green: Double((hex >> 8) & 0xFF) / 255.0,
        blue: Double(hex & 0xFF) / 255.0,
        opacity: alpha
    )
}

/// 弹出面板配色方案。`.system` 与 `.appearance` 会动态解析为 `.white` 或 `.black`，其余四套预设均使用显式 sRGB 颜色，不受系统深浅色影响。
public nonisolated struct CalendarPopoverPalette: Sendable {
    public let usesDarkGrid: Bool

    // 顶部操作栏
    public let headerBackground: Color
    public let headerText: Color
    public let headerControlBackground: Color
    public let headerControlBorder: Color
    public let headerHoverBackground: Color
    public let todayButtonBackground: Color
    public let todayButtonText: Color
    public let todayButtonBorder: Color

    // 星期表头
    public let weekdayBarBackground: Color
    public let weekdayText: Color
    public let weekdayWeekendText: Color

    // 日历网格与日期格子
    public let gridBackground: Color
    public let gridBorder: Color
    public let dayText: Color
    public let weekendDayText: Color
    public let lunarText: Color
    public let specialLunarText: Color
    public let hoverBackground: Color

    // 节假日（休）与调休上班（班）高亮
    public let holidayCellBackground: Color
    public let holidayBadgeBackground: Color
    public let holidayBadgeText: Color
    public let makeupCellBackground: Color
    public let makeupBadgeBackground: Color
    public let makeupBadgeText: Color

    // 选中与今天边框/角标
    public let selectedBorder: Color
    public let todayBorder: Color
    public let todayBadgeBackground: Color
    public let todayBadgeText: Color

    // 右侧详情栏
    public let sidebarBackground: Color
    public let sidebarDivider: Color?
    public let sidebarText: Color
    public let sidebarSecondaryText: Color
    public let sidebarTertiaryText: Color
    public let sidebarDividerLine: Color
    public let sidebarHoverBackground: Color
    public let sidebarPillBackground: Color
    public let sidebarPillText: Color
    public let sidebarHolidayPillBackground: Color
    public let sidebarHolidayPillText: Color
    public let sidebarMakeupPillBackground: Color
    public let sidebarMakeupPillText: Color
    public let daySquareBackground: Color
    public let daySquareText: Color

    // 底部倒计时栏
    public let footerText: Color

    // 弹出下拉面板（年份 / 月份 / 样式）
    public let dropdownBackground: Color
    public let dropdownBorder: Color
    public let dropdownText: Color
    public let dropdownHoverBackground: Color
    public let dropdownSelectedBackground: Color
    public let dropdownSelectedText: Color
    public let dropdownCheckmark: Color

    // MARK: - 预设主题

    public static let white = CalendarPopoverPalette(
        usesDarkGrid: false,
        headerBackground: srgb(0xFAFAFB),
        headerText: srgb(0x18181B),
        headerControlBackground: srgb(0xFFFFFF),
        headerControlBorder: srgb(0x000000, 0.12),
        headerHoverBackground: srgb(0x000000, 0.06),
        todayButtonBackground: srgb(0xFFFFFF),
        todayButtonText: srgb(0x18181B),
        todayButtonBorder: srgb(0x000000, 0.12),
        weekdayBarBackground: srgb(0xF5F5F7),
        weekdayText: srgb(0x52525B),
        weekdayWeekendText: srgb(0xDC2626),
        gridBackground: srgb(0xFFFFFF),
        gridBorder: srgb(0x000000, 0.08),
        dayText: srgb(0x18181B),
        weekendDayText: srgb(0xE02424),
        lunarText: srgb(0x71717A),
        specialLunarText: srgb(0xDC2626),
        hoverBackground: srgb(0x000000, 0.045),
        holidayCellBackground: srgb(0xFDECEE),
        holidayBadgeBackground: srgb(0xE83B33),
        holidayBadgeText: .white,
        makeupCellBackground: srgb(0xEFEFF2),
        makeupBadgeBackground: srgb(0x757B86),
        makeupBadgeText: .white,
        selectedBorder: srgb(0xF59E24),
        todayBorder: srgb(0xF59E24),
        todayBadgeBackground: srgb(0xF59E24),
        todayBadgeText: .white,
        sidebarBackground: srgb(0xF7F7F8),
        sidebarDivider: srgb(0x000000, 0.08),
        sidebarText: srgb(0x18181B),
        sidebarSecondaryText: srgb(0x52525B),
        sidebarTertiaryText: srgb(0x71717A),
        sidebarDividerLine: srgb(0x000000, 0.08),
        sidebarHoverBackground: srgb(0x000000, 0.06),
        sidebarPillBackground: srgb(0xF59E24, 0.15),
        sidebarPillText: srgb(0xB45309),
        sidebarHolidayPillBackground: srgb(0xE83B33, 0.14),
        sidebarHolidayPillText: srgb(0xC81E1E),
        sidebarMakeupPillBackground: srgb(0x52525B, 0.14),
        sidebarMakeupPillText: srgb(0x3F3F46),
        daySquareBackground: srgb(0xF59E24),
        daySquareText: .white,
        footerText: srgb(0x71717A),
        dropdownBackground: srgb(0xFFFFFF),
        dropdownBorder: srgb(0x000000, 0.12),
        dropdownText: srgb(0x18181B),
        dropdownHoverBackground: srgb(0x000000, 0.06),
        dropdownSelectedBackground: srgb(0xF4F4F5),
        dropdownSelectedText: srgb(0x18181B),
        dropdownCheckmark: srgb(0x16B38A)
    )

    public static let black = CalendarPopoverPalette(
        usesDarkGrid: true,
        headerBackground: srgb(0x1E1E22),
        headerText: srgb(0xF4F4F5),
        headerControlBackground: srgb(0x2A2A2F),
        headerControlBorder: srgb(0xFFFFFF, 0.14),
        headerHoverBackground: srgb(0xFFFFFF, 0.08),
        todayButtonBackground: srgb(0x2A2A2F),
        todayButtonText: srgb(0xF4F4F5),
        todayButtonBorder: srgb(0xFFFFFF, 0.14),
        weekdayBarBackground: srgb(0x18181B),
        weekdayText: srgb(0xA1A1AA),
        weekdayWeekendText: srgb(0xFF6B6B),
        gridBackground: srgb(0x121214),
        gridBorder: srgb(0xFFFFFF, 0.09),
        dayText: srgb(0xF4F4F5),
        weekendDayText: srgb(0xFF6B6B),
        lunarText: srgb(0xA1A1AA),
        specialLunarText: srgb(0xFF6B6B),
        hoverBackground: srgb(0xFFFFFF, 0.07),
        holidayCellBackground: srgb(0xE53935, 0.22),
        holidayBadgeBackground: srgb(0xEB423A),
        holidayBadgeText: .white,
        makeupCellBackground: srgb(0xFFFFFF, 0.10),
        makeupBadgeBackground: srgb(0x6E7685),
        makeupBadgeText: .white,
        selectedBorder: srgb(0xFFB840),
        todayBorder: srgb(0xFFB840),
        todayBadgeBackground: srgb(0xF59E24),
        todayBadgeText: .white,
        sidebarBackground: srgb(0x1C1C20),
        sidebarDivider: srgb(0xFFFFFF, 0.09),
        sidebarText: srgb(0xF4F4F5),
        sidebarSecondaryText: srgb(0xD4D4D8),
        sidebarTertiaryText: srgb(0xA1A1AA),
        sidebarDividerLine: srgb(0xFFFFFF, 0.10),
        sidebarHoverBackground: srgb(0xFFFFFF, 0.09),
        sidebarPillBackground: srgb(0xFFB840, 0.18),
        sidebarPillText: srgb(0xFFD166),
        sidebarHolidayPillBackground: srgb(0xEB423A, 0.24),
        sidebarHolidayPillText: srgb(0xFF8A85),
        sidebarMakeupPillBackground: srgb(0xFFFFFF, 0.14),
        sidebarMakeupPillText: srgb(0xE4E4E7),
        daySquareBackground: srgb(0xF59E24),
        daySquareText: .white,
        footerText: srgb(0xA1A1AA),
        dropdownBackground: srgb(0x242429),
        dropdownBorder: srgb(0xFFFFFF, 0.14),
        dropdownText: srgb(0xF4F4F5),
        dropdownHoverBackground: srgb(0xFFFFFF, 0.09),
        dropdownSelectedBackground: srgb(0xFFFFFF, 0.10),
        dropdownSelectedText: srgb(0xF4F4F5),
        dropdownCheckmark: srgb(0x1FC79B)
    )

    public static let red = CalendarPopoverPalette(
        usesDarkGrid: false,
        headerBackground: srgb(0xFA3423),
        headerText: .white,
        headerControlBackground: srgb(0xFFFFFF, 0.18),
        headerControlBorder: srgb(0xFFFFFF, 0.38),
        headerHoverBackground: srgb(0xFFFFFF, 0.22),
        todayButtonBackground: srgb(0xFFFFFF),
        todayButtonText: srgb(0x27272A),
        todayButtonBorder: .clear,
        weekdayBarBackground: srgb(0xF6F6F7),
        weekdayText: srgb(0x52525B),
        weekdayWeekendText: srgb(0xE02424),
        gridBackground: srgb(0xFFFFFF),
        gridBorder: srgb(0x000000, 0.07),
        dayText: srgb(0x1F2937),
        weekendDayText: srgb(0xE02424),
        lunarText: srgb(0x71717A),
        specialLunarText: srgb(0xE02424),
        hoverBackground: srgb(0x000000, 0.045),
        holidayCellBackground: srgb(0xFDECEE),
        holidayBadgeBackground: srgb(0xE83B33),
        holidayBadgeText: .white,
        makeupCellBackground: srgb(0xEFEFF2),
        makeupBadgeBackground: srgb(0x757B86),
        makeupBadgeText: .white,
        selectedBorder: srgb(0xF7B200),
        todayBorder: srgb(0xF7B200),
        todayBadgeBackground: srgb(0xF7B200),
        todayBadgeText: .white,
        sidebarBackground: srgb(0xFA3423),
        sidebarDivider: nil,
        sidebarText: .white,
        sidebarSecondaryText: srgb(0xFFFFFF, 0.88),
        sidebarTertiaryText: srgb(0xFFFFFF, 0.72),
        sidebarDividerLine: srgb(0xFFFFFF, 0.22),
        sidebarHoverBackground: srgb(0xFFFFFF, 0.18),
        sidebarPillBackground: srgb(0xFFFFFF, 0.22),
        sidebarPillText: .white,
        sidebarHolidayPillBackground: srgb(0xFFFFFF),
        sidebarHolidayPillText: srgb(0xD92D20),
        sidebarMakeupPillBackground: srgb(0x18181B, 0.34),
        sidebarMakeupPillText: .white,
        daySquareBackground: srgb(0xF7B200),
        daySquareText: .white,
        footerText: srgb(0x71717A),
        dropdownBackground: srgb(0xFFFFFF),
        dropdownBorder: srgb(0x000000, 0.12),
        dropdownText: srgb(0x18181B),
        dropdownHoverBackground: srgb(0x000000, 0.06),
        dropdownSelectedBackground: srgb(0xF4F4F5),
        dropdownSelectedText: srgb(0x18181B),
        dropdownCheckmark: srgb(0x16B38A)
    )

    public static let blue = CalendarPopoverPalette(
        usesDarkGrid: false,
        headerBackground: srgb(0x18A4FA),
        headerText: .white,
        headerControlBackground: srgb(0xFFFFFF, 0.18),
        headerControlBorder: srgb(0xFFFFFF, 0.38),
        headerHoverBackground: srgb(0xFFFFFF, 0.22),
        todayButtonBackground: srgb(0xFFFFFF),
        todayButtonText: srgb(0x27272A),
        todayButtonBorder: .clear,
        weekdayBarBackground: srgb(0xF6F6F7),
        weekdayText: srgb(0x52525B),
        weekdayWeekendText: srgb(0xE02424),
        gridBackground: srgb(0xFFFFFF),
        gridBorder: srgb(0x000000, 0.07),
        dayText: srgb(0x1F2937),
        weekendDayText: srgb(0xE02424),
        lunarText: srgb(0x71717A),
        specialLunarText: srgb(0xE02424),
        hoverBackground: srgb(0x000000, 0.045),
        holidayCellBackground: srgb(0xFDECEE),
        holidayBadgeBackground: srgb(0xE83B33),
        holidayBadgeText: .white,
        makeupCellBackground: srgb(0xEFEFF2),
        makeupBadgeBackground: srgb(0x757B86),
        makeupBadgeText: .white,
        selectedBorder: srgb(0xF7B200),
        todayBorder: srgb(0xF7B200),
        todayBadgeBackground: srgb(0xF7B200),
        todayBadgeText: .white,
        sidebarBackground: srgb(0x18A4FA),
        sidebarDivider: nil,
        sidebarText: .white,
        sidebarSecondaryText: srgb(0xFFFFFF, 0.88),
        sidebarTertiaryText: srgb(0xFFFFFF, 0.72),
        sidebarDividerLine: srgb(0xFFFFFF, 0.22),
        sidebarHoverBackground: srgb(0xFFFFFF, 0.18),
        sidebarPillBackground: srgb(0xFFFFFF, 0.22),
        sidebarPillText: .white,
        sidebarHolidayPillBackground: srgb(0xFFFFFF),
        sidebarHolidayPillText: srgb(0xD92D20),
        sidebarMakeupPillBackground: srgb(0x18181B, 0.34),
        sidebarMakeupPillText: .white,
        daySquareBackground: srgb(0xF7B200),
        daySquareText: .white,
        footerText: srgb(0x71717A),
        dropdownBackground: srgb(0xFFFFFF),
        dropdownBorder: srgb(0x000000, 0.12),
        dropdownText: srgb(0x18181B),
        dropdownHoverBackground: srgb(0x000000, 0.06),
        dropdownSelectedBackground: srgb(0xF4F4F5),
        dropdownSelectedText: srgb(0x18181B),
        dropdownCheckmark: srgb(0x16B38A)
    )
}
