import AppKit
import SwiftUI

// 饭碗设计系统：参考 WorkBuddy —— 浅灰侧栏、白色内容区、细边框白卡、黑色主按钮、绿色开关、大量留白。
// 所有颜色都随系统深浅色自动切换。

public extension Color {
    /// 浅色 / 深色两套取值。
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

public enum DS {
    // MARK: 颜色
    public static let sidebar = Color(light: hex(0xF7F7F8), dark: hex(0x1C1C1E))
    public static let canvas = Color(light: hex(0xFFFFFF), dark: hex(0x141416))
    /// 设置页这类"灰底白卡"的底色。
    public static let groupBackground = Color(light: hex(0xF5F5F7), dark: hex(0x141416))
    public static let card = Color(light: hex(0xFFFFFF), dark: hex(0x222225))
    /// 指标卡这类无边框的浅灰块。
    public static let well = Color(light: hex(0xF4F4F5), dark: hex(0x232326))
    public static let border = Color(light: hex(0x000000, 0.06), dark: hex(0xFFFFFF, 0.09))
    public static let borderStrong = Color(light: hex(0x000000, 0.10), dark: hex(0xFFFFFF, 0.15))
    public static let hover = Color(light: hex(0x000000, 0.04), dark: hex(0xFFFFFF, 0.06))
    public static let selected = Color(light: hex(0x000000, 0.065), dark: hex(0xFFFFFF, 0.10))
    public static let pickerSelected = Color(light: hex(0xF4F4F5), dark: hex(0xFFFFFF, 0.10))
    public static let primaryFill = Color(light: hex(0x18181B), dark: hex(0xF4F4F5))
    public static let onPrimary = Color(light: hex(0xFFFFFF), dark: hex(0x18181B))
    public static let toggle = Color(light: hex(0x16B38A), dark: hex(0x1FC79B))
    public static let brand = Color(light: hex(0xF59E24), dark: hex(0xFFB840))
    public static let text = Color.primary
    public static let textSecondary = Color.secondary
    public static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    public static let danger = Color(light: hex(0xDC3B3B), dark: hex(0xF07070))
    public static let warning = Color(light: hex(0xB76E00), dark: hex(0xF5B54A))
    public static let success = Color(light: hex(0x13875F), dark: hex(0x3DD39A))

    // MARK: 字体（随「外观 → 字体大小」整体缩放）

    /// 字体缩放倍数，1 = 默认。改了之后根视图要用 `.id(DS.fontScale)` 重建才会刷新。
    public static var fontScale: CGFloat = 1

    public static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * fontScale, weight: weight)
    }

    public static func mono(_ size: CGFloat) -> Font {
        .system(size: size * fontScale, design: .monospaced)
    }

    public static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * fontScale, weight: weight, design: .serif)
    }

    /// 跟着字号一起缩放的尺寸（控件高度等）。
    public static func s(_ v: CGFloat) -> CGFloat { (v * fontScale).rounded() }

    public static var heroTitle: Font { font(28, .semibold) }
    public static var pageTitle: Font { font(18, .semibold) }
    public static var sectionTitle: Font { font(14, .medium) }
    public static var rowTitle: Font { font(14.5, .medium) }
    public static var body: Font { font(14) }
    public static var caption: Font { font(12.5) }

    public static let radius: CGFloat = 12
    public static let controlRadius: CGFloat = 8
}

// MARK: - 卡片

/// 细边框白卡。
public struct DSCard<Content: View>: View {
    var padding: CGFloat
    var dashed: Bool
    @ViewBuilder var content: Content

    public init(padding: CGFloat = 14, dashed: Bool = false, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.dashed = dashed
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.card, in: .rect(cornerRadius: DS.radius))
            .overlay {
                RoundedRectangle(cornerRadius: DS.radius)
                    .strokeBorder(dashed ? DS.borderStrong : DS.border,
                                  style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
            }
    }
}

/// 无边框浅灰指标块：小字标签 + 大号数字。
public struct DSMetric: View {
    let label: String
    let value: String
    let detail: String?
    let valueColor: Color

    public init(_ label: String, value: String, detail: String? = nil, valueColor: Color = DS.text) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(DS.caption).foregroundStyle(DS.textSecondary)
            Text(value).font(DS.font(21, .semibold)).monospacedDigit().foregroundStyle(valueColor)
            if let detail { Text(detail).font(DS.caption).foregroundStyle(DS.textTertiary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.well, in: .rect(cornerRadius: 10))
    }
}

/// 提示条（错误 / 成功 / 提醒）。
public struct DSBanner: View {
    public enum Kind { case info, success, warning, danger }
    let kind: Kind
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ kind: Kind, _ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
        self.action = action
    }

    var color: Color {
        switch kind {
        case .info: DS.textSecondary
        case .success: DS.success
        case .warning: DS.warning
        case .danger: DS.danger
        }
    }

    var icon: String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "xmark.octagon"
        }
    }

    public var body: some View {
        HStack(alignment: actionTitle == nil ? .firstTextBaseline : .center, spacing: 8) {
            Image(systemName: icon)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.dsSecondary)
            }
        }
        .font(DS.body)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: .rect(cornerRadius: 10))
    }
}

// MARK: - 按钮

public struct DSPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        DSPrimaryButtonBody(configuration: configuration)
    }
}

private struct DSPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(DS.font(14, .medium))
            .foregroundStyle(DS.onPrimary)
            .padding(.horizontal, 14)
            .frame(height: DS.s(30))
            .background(DS.primaryFill.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: .rect(cornerRadius: DS.controlRadius))
            .contentShape(.rect)
    }
}

public struct DSSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        DSSecondaryButtonBody(configuration: configuration)
    }
}

private struct DSSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(DS.font(14))
            .foregroundStyle(enabled ? DS.text : DS.textTertiary)
            .padding(.horizontal, 12)
            .frame(height: DS.s(30))
            .background(configuration.isPressed ? DS.selected : hovering ? DS.hover : DS.card,
                        in: .rect(cornerRadius: DS.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// 只有图标或文字的轻按钮（悬停才有底色）。
public struct DSGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        DSGhostButtonBody(configuration: configuration)
    }
}

private struct DSGhostButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(DS.font(14))
            .foregroundStyle(DS.textSecondary)
            .padding(.horizontal, 7)
            .frame(minWidth: DS.s(28), minHeight: DS.s(28))
            .background(configuration.isPressed ? DS.selected : hovering ? DS.hover : .clear,
                        in: .rect(cornerRadius: DS.controlRadius))
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// 胶囊标签按钮（首页快捷操作）。
public struct DSChipButtonStyle: ButtonStyle {
    var selected: Bool
    public init(selected: Bool = false) { self.selected = selected }
    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        DSChipBody(configuration: configuration, selected: selected)
    }
}

private struct DSChipBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(DS.font(13.5))
            .foregroundStyle(DS.text)
            .padding(.horizontal, 12)
            .frame(height: DS.s(28))
            .background(selected || configuration.isPressed ? DS.selected : hovering ? DS.hover : DS.card, in: .capsule)
            .overlay { Capsule().strokeBorder(selected ? .clear : DS.borderStrong) }
            .contentShape(.capsule)
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
}
public extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
}
public extension ButtonStyle where Self == DSGhostButtonStyle {
    static var dsGhost: DSGhostButtonStyle { DSGhostButtonStyle() }
}
public extension ButtonStyle where Self == DSChipButtonStyle {
    static var dsChip: DSChipButtonStyle { DSChipButtonStyle() }
    static func dsChip(selected: Bool) -> DSChipButtonStyle { DSChipButtonStyle(selected: selected) }
}

// MARK: - 侧栏条目

public struct DSSidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let badge: String?
    let badgeColor: Color?
    let action: () -> Void
    @State private var hovering = false

    public init(
        _ title: String,
        systemImage: String,
        selected: Bool,
        badge: String? = nil,
        badgeColor: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.badge = badge
        self.badgeColor = badgeColor
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(DS.font(15))
                    .frame(width: DS.s(18))
                Text(title).font(DS.font(14.5))
                Spacer(minLength: 0)
                if let badge {
                    if let badgeColor {
                        Text(badge)
                            .font(DS.font(10.5, .semibold))
                            .foregroundStyle(badgeColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.14), in: .capsule)
                            .overlay { Capsule().strokeBorder(badgeColor.opacity(0.32)) }
                    } else {
                        Text(badge).font(DS.font(11.5)).foregroundStyle(DS.textTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay { Capsule().strokeBorder(DS.border) }
                    }
                }
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 10)
            .frame(height: DS.s(30))
            .background(selected ? DS.selected : hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 侧栏里的小节标题（"最近"、"分组"）。
public struct DSSidebarSection: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public var body: some View {
        Text(title).font(DS.font(12.5)).foregroundStyle(DS.textTertiary)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 标签页（全部 (1) / 进行中 / 已暂停）

public struct DSTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    public init(selection: Binding<Value>, options: [(Value, String)]) {
        _selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection = value }
                    .buttonStyle(DSTabButtonStyle(selected: selection == value))
            }
        }
    }
}

struct DSTabButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(DS.font(13.5, selected ? .medium : .regular))
            .foregroundStyle(selected ? DS.text : DS.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: DS.s(26))
            .background(selected ? DS.selected : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
    }
}

// MARK: - 设置行

/// 设置分组：灰色小标题 + 白卡，里面的行之间有分隔线。
public struct DSSection<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(DS.sectionTitle).foregroundStyle(DS.textSecondary).padding(.leading, 4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { i in
                        subviews[i]
                        if i < subviews.count - 1 {
                            Divider().overlay(DS.border).padding(.horizontal, 16)
                        }
                    }
                }
            }
            .background(DS.card, in: .rect(cornerRadius: DS.radius))
            .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
            if let footer {
                Text(footer).font(DS.caption).foregroundStyle(DS.textTertiary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 设置行：左边粗体标题 + 灰色说明，右边控件。
public struct DSRow<Trailing: View>: View {
    let title: String
    let description: String?
    @ViewBuilder var trailing: Trailing

    public init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.rowTitle)
                if let description {
                    Text(description).font(DS.caption).foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: DS.s(52))
    }
}

/// 设置行里占满宽度的内容（比如文本编辑器、列表）。
public struct DSBlockRow<Content: View>: View {
    @ViewBuilder var content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content.padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 绿色开关。
public struct DSToggle: View {
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { _isOn = isOn }
    public var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).tint(DS.toggle).labelsHidden().controlSize(.small)
    }
}

/// 带边框的输入框。
public struct DSTextFieldStyle: TextFieldStyle {
    public init() {}
    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(DS.font(14))
            .padding(.horizontal, 10)
            .frame(height: DS.s(30))
            .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
    }
}

public extension TextFieldStyle where Self == DSTextFieldStyle {
    static var ds: DSTextFieldStyle { DSTextFieldStyle() }
}

/// 数字步进：[-] 值 [+]
public struct DSStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    public init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1, format: @escaping (Double) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: DS.s(26), height: DS.s(28)) }
            Text(format(value)).font(DS.font(14).monospacedDigit()).frame(minWidth: DS.s(52))
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: DS.s(26), height: DS.s(28)) }
        }
        .buttonStyle(.plain)
        .font(DS.font(12, .semibold))
        .foregroundStyle(DS.text)
        .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
    }
}

public extension DSStepper {
    /// 整数版本。
    init(intValue: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1, format: @escaping (Int) -> String) {
        self.init(value: Binding(get: { Double(intValue.wrappedValue) }, set: { intValue.wrappedValue = Int($0) }),
                  in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step),
                  format: { format(Int($0)) })
    }
}

/// 页面顶部：左边标题（+ 标签页），右边操作。
public struct DSPageHeader<Leading: View, Actions: View>: View {
    let title: String
    let topPadding: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    public init(
        _ title: String,
        topPadding: CGFloat = 0,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.topPadding = topPadding
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 14) {
            Text(title).font(DS.pageTitle)
            leading
            Spacer()
            actions
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
        .padding(.top, topPadding)
        .windowTitleBar()
    }
}

public extension EnvironmentValues {
    /// 主窗口侧边栏是否处于收起状态（收起时内容区左上角要给展开按钮让位置）。
    @Entry var sidebarCollapsed = false
}

// MARK: - 品牌标语

public enum DSSloganStyle: Sendable {
    case hero
    case sidebar
    case banner
    case inline
}

/// 饭碗全局品牌标语展示组件：无框衬线排版配合纤细暖琥珀竖线/细线点缀。
public struct DSSloganView: View {
    let text: String
    let style: DSSloganStyle

    public init(_ text: String = AppBrand.slogan, style: DSSloganStyle = .inline) {
        self.text = text
        self.style = style
    }

    private var sidebarText: String {
        text == AppBrand.slogan ? AppBrand.twoLineSlogan : text
    }

    public var body: some View {
        switch style {
        case .hero:
            HStack(spacing: 10) {
                Capsule()
                    .fill(DS.brand.opacity(0.55))
                    .frame(width: 18, height: 1.5)
                Text(text)
                    .font(DS.serif(15.5, .medium))
                    .tracking(1.0)
                    .foregroundStyle(DS.text.opacity(0.84))
                Capsule()
                    .fill(DS.brand.opacity(0.55))
                    .frame(width: 18, height: 1.5)
            }

        case .sidebar:
            Text(sidebarText)
                .font(DS.serif(12, .medium))
                .tracking(0.3)
                .foregroundStyle(DS.text.opacity(0.76))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DS.brand.opacity(0.75))
                        .frame(width: 2)
                        .padding(.vertical, 1.5)
                }

        case .banner:
            Text(text)
                .font(DS.serif(13, .medium))
                .tracking(0.5)
                .foregroundStyle(DS.text.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(DS.brand.opacity(0.75))
                        .frame(width: 2.5)
                        .padding(.vertical, 1.5)
                }

        case .inline:
            Text(text)
                .font(DS.serif(12.5, .medium))
                .tracking(0.4)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}
