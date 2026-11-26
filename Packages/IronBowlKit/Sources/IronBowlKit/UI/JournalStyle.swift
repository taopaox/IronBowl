import AppKit
import SwiftUI

private func jHex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255,
        alpha: a
    )
}

// MARK: - 纸感预设与高亮持久化

public nonisolated enum JournalPaperPreset: String, Codable, Sendable, CaseIterable {
    case warm
    case clean

    public var displayName: String {
        switch self {
        case .warm: "暖米手账"
        case .clean: "清爽象牙"
        }
    }

    public var shortName: String {
        switch self {
        case .warm: "暖米"
        case .clean: "象牙"
        }
    }
}

public nonisolated enum JournalKeys {
    public static let paperPreset = SettingKey<JournalPaperPreset>("journal.paperPreset", default: .warm)
    public static let highlightedItems = SettingKey<[String]>("journal.highlightedItems", default: [])
}

/// 跨「日报」与「周报/月报」共享的荧光笔重点标记。
public nonisolated enum JournalHighlight {
    public static let maxStoredCount = 200

    public static func key(date: String, work: String) -> String {
        let normalized = work
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !date.isEmpty, !normalized.isEmpty else { return "" }
        return "\(date)|\(normalized)"
    }

    @MainActor
    public static func isHighlighted(date: String, work: String, in settings: SettingsStore) -> Bool {
        let k = key(date: date, work: work)
        guard !k.isEmpty else { return false }
        return settings[JournalKeys.highlightedItems].contains(k)
    }

    @MainActor
    public static func toggle(date: String, work: String, in settings: SettingsStore) {
        let k = key(date: date, work: work)
        guard !k.isEmpty else { return }
        var list = settings[JournalKeys.highlightedItems]
        if let idx = list.firstIndex(of: k) {
            list.remove(at: idx)
        } else {
            list.append(k)
            if list.count > maxStoredCount {
                list.removeFirst(list.count - maxStoredCount)
            }
        }
        settings[JournalKeys.highlightedItems] = list
    }
}

// MARK: - 手账调色板（自适应浅色 / 深色模式）

public struct JournalPalette: Sendable {
    public let preset: JournalPaperPreset

    public init(preset: JournalPaperPreset) {
        self.preset = preset
    }

    public var desk: Color {
        switch preset {
        case .warm: Color(light: jHex(0xE8E1D3), dark: jHex(0x141210))
        case .clean: Color(light: jHex(0xECEBE7), dark: jHex(0x141413))
        }
    }

    public var cover: Color {
        switch preset {
        case .warm: Color(light: jHex(0x8C6244), dark: jHex(0x3D2E22))
        case .clean: Color(light: jHex(0x6E6B64), dark: jHex(0x2F2E2B))
        }
    }

    public var paper: Color {
        switch preset {
        case .warm: Color(light: jHex(0xFBF7EF), dark: jHex(0x211E1B))
        case .clean: Color(light: jHex(0xFCFBF8), dark: jHex(0x1D1C1A))
        }
    }

    public var paperAlt: Color {
        switch preset {
        case .warm: Color(light: jHex(0xF5EFE3), dark: jHex(0x282420))
        case .clean: Color(light: jHex(0xF5F4EF), dark: jHex(0x232220))
        }
    }

    public var paperCard: Color {
        switch preset {
        case .warm: Color(light: jHex(0xFFFDF9), dark: jHex(0x2A2622))
        case .clean: Color(light: jHex(0xFFFFFF), dark: jHex(0x252422))
        }
    }

    public var spine: Color {
        switch preset {
        case .warm: Color(light: jHex(0xE4D8C4), dark: jHex(0x1A1714))
        case .clean: Color(light: jHex(0xE3E2DC), dark: jHex(0x191817))
        }
    }

    public var paperLine: Color {
        switch preset {
        case .warm: Color(light: jHex(0xA28E72, 0.20), dark: jHex(0xFFE0B4, 0.08))
        case .clean: Color(light: jHex(0x787872, 0.13), dark: jHex(0xFFFFFF, 0.06))
        }
    }

    public var paperGrid: Color {
        switch preset {
        case .warm: Color(light: jHex(0xA28E72, 0.08), dark: jHex(0xFFE0B4, 0.035))
        case .clean: Color(light: jHex(0x787872, 0.05), dark: jHex(0xFFFFFF, 0.03))
        }
    }

    public var border: Color {
        switch preset {
        case .warm: Color(light: jHex(0x58442E, 0.14), dark: jHex(0xFFE4C4, 0.11))
        case .clean: Color(light: jHex(0x000000, 0.09), dark: jHex(0xFFFFFF, 0.10))
        }
    }

    public var borderStrong: Color {
        switch preset {
        case .warm: Color(light: jHex(0x58442E, 0.24), dark: jHex(0xFFE4C4, 0.22))
        case .clean: Color(light: jHex(0x000000, 0.17), dark: jHex(0xFFFFFF, 0.19))
        }
    }

    public var ink: Color {
        switch preset {
        case .warm: Color(light: jHex(0x2B231D), dark: jHex(0xEFE7DC))
        case .clean: Color(light: jHex(0x1F1F1D), dark: jHex(0xF1F0EC))
        }
    }

    public var inkSecondary: Color {
        switch preset {
        case .warm: Color(light: jHex(0x66584B), dark: jHex(0xB9AB99))
        case .clean: Color(light: jHex(0x5C5C57), dark: jHex(0xACACA5))
        }
    }

    public var inkTertiary: Color {
        switch preset {
        case .warm: Color(light: jHex(0x99897A), dark: jHex(0x827566))
        case .clean: Color(light: jHex(0x8F8F88), dark: jHex(0x7A7A73))
        }
    }

    public var stampRed: Color {
        Color(light: jHex(0xC83E37), dark: jHex(0xEF6F68))
    }

    public var stampGreen: Color {
        Color(light: jHex(0x18794E), dark: jHex(0x4ADE80))
    }

    public var stampAmber: Color {
        Color(light: jHex(0xB45309), dark: jHex(0xFBBF24))
    }

    public var stampPurple: Color {
        Color(light: jHex(0x6D28D9), dark: jHex(0xC084FC))
    }

    public var stampBlue: Color {
        Color(light: jHex(0x2B59C3), dark: jHex(0x7AA2F7))
    }

    public var stickyFill: Color {
        Color(light: jHex(0xFEF7CD), dark: jHex(0x332C19))
    }

    public var stickyBorder: Color {
        Color(light: jHex(0xEADB89), dark: jHex(0x5C4D26))
    }

    public var highlightFill: Color {
        Color(light: jHex(0xFEF08A, 0.72), dark: jHex(0xFACC15, 0.24))
    }

    public static func serif(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size * DS.fontScale, weight: weight, design: .serif)
    }
}

// MARK: - 章节与双页活页手账外壳

public enum JournalChapter: String, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly

    public var title: String {
        switch self {
        case .daily: "日报"
        case .weekly: "周报"
        case .monthly: "月报"
        }
    }

    public var fullTitle: String {
        switch self {
        case .daily: "每日手账"
        case .weekly: "本周汇总"
        case .monthly: "本月归档"
        }
    }

    public func tabColor(in palette: JournalPalette) -> Color {
        switch self {
        case .daily: palette.stampRed
        case .weekly: palette.stampGreen
        case .monthly: palette.stampBlue
        }
    }
}

public struct JournalSpreadShell<HeaderActions: View, LeftPage: View, RightPage: View>: View {
    let chapter: JournalChapter
    let settings: SettingsStore
    let showHistoryTab: Bool
    let onSelectChapter: ((JournalChapter) -> Void)?
    let onOpenHistory: (() -> Void)?
    @ViewBuilder let headerActions: HeaderActions
    @ViewBuilder let leftPage: LeftPage
    @ViewBuilder let rightPage: RightPage

    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    public init(
        chapter: JournalChapter,
        settings: SettingsStore,
        showHistoryTab: Bool = false,
        onSelectChapter: ((JournalChapter) -> Void)? = nil,
        onOpenHistory: (() -> Void)? = nil,
        @ViewBuilder headerActions: () -> HeaderActions,
        @ViewBuilder leftPage: () -> LeftPage,
        @ViewBuilder rightPage: () -> RightPage
    ) {
        self.chapter = chapter
        self.settings = settings
        self.showHistoryTab = showHistoryTab
        self.onSelectChapter = onSelectChapter
        self.onOpenHistory = onOpenHistory
        self.headerActions = headerActions()
        self.leftPage = leftPage()
        self.rightPage = rightPage()
    }

    private var preset: JournalPaperPreset {
        settings[JournalKeys.paperPreset]
    }

    private var palette: JournalPalette {
        JournalPalette(preset: preset)
    }

    public var body: some View {
        let p = palette
        VStack(spacing: 0) {
            topBar(palette: p)

            GeometryReader { geo in
                if geo.size.width >= 860 {
                    HStack(alignment: .top, spacing: 0) {
                        HStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    leftPage
                                }
                                .padding(18)
                            }
                            .scrollIndicators(.never)
                            .frame(width: min(380, max(300, geo.size.width * 0.34)))
                            .background {
                                p.paperAlt
                                JournalGridBackground(lineColor: p.paperGrid)
                            }

                            JournalBinderSpine(palette: p)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    rightPage
                                }
                                .padding(.horizontal, 26)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .scrollIndicators(.never)
                            .background {
                                p.paper
                                JournalRuledBackground(lineColor: p.paperLine)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 10))
                        .padding(5)
                        .background(p.cover, in: .rect(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)

                        if onSelectChapter != nil || (showHistoryTab && onOpenHistory != nil) {
                            JournalIndexTabs(
                                activeChapter: chapter,
                                showHistory: showHistoryTab && onOpenHistory != nil,
                                palette: p,
                                onSelectChapter: onSelectChapter,
                                onOpenHistory: onOpenHistory
                            )
                            .padding(.top, 24)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let onSelectChapter {
                                HStack(spacing: 6) {
                                    ForEach(JournalChapter.allCases, id: \.self) { ch in
                                        let active = ch == chapter
                                        Button(ch.title) { onSelectChapter(ch) }
                                            .buttonStyle(.plain)
                                            .font(DS.font(12.5, active ? .bold : .medium))
                                            .foregroundStyle(active ? .white : p.inkSecondary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(active ? ch.tabColor(in: p) : p.paperAlt, in: .capsule)
                                    }
                                    Spacer()
                                }
                            }
                            VStack(alignment: .leading, spacing: 14) {
                                rightPage
                            }
                            .padding(18)
                            .background(p.paper, in: .rect(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.borderStrong) }

                            VStack(alignment: .leading, spacing: 14) {
                                leftPage
                            }
                            .padding(16)
                            .background(p.paperAlt, in: .rect(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.border) }
                        }
                        .padding(14)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .background(p.desk)
    }

    private func topBar(palette p: JournalPalette) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(chapter.fullTitle)
                    .font(JournalPalette.serif(17, .bold))
                    .foregroundStyle(p.ink)

                HStack(spacing: 2) {
                    ForEach(JournalPaperPreset.allCases, id: \.self) { item in
                        let selected = preset == item
                        Button {
                            settings[JournalKeys.paperPreset] = item
                        } label: {
                            Text(item.shortName)
                                .font(DS.font(11.5, selected ? .semibold : .regular))
                                .foregroundStyle(selected ? p.ink : p.inkTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(selected ? p.paperCard : .clear, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(p.paperAlt.opacity(0.9), in: .capsule)
                .overlay { Capsule().strokeBorder(p.border) }
                .help("切换手账纸感风格")
            }

            Spacer(minLength: 8)
            headerActions
        }
        .padding(.leading, sidebarCollapsed ? 120 : 20)
        .padding(.trailing, 20)
        .frame(height: 46)
        .padding(.top, 6)
        .windowTitleBar()
    }
}

// MARK: - 活页书脊、纸张纹路与索引贴签

private struct JournalBinderSpine: View {
    let palette: JournalPalette

    var body: some View {
        ZStack {
            Rectangle()
                .fill(palette.spine)
            HStack(spacing: 0) {
                Rectangle().fill(palette.border).frame(width: 1)
                Spacer()
                Rectangle().fill(palette.border).frame(width: 1)
            }
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    Spacer(minLength: 14)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.55), Color(white: 0.92), Color(white: 0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 18, height: 7)
                        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                }
                Spacer(minLength: 14)
            }
        }
        .frame(width: 22)
    }
}

private struct JournalGridBackground: View {
    let lineColor: Color

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 20
            var path = Path()
            var x: CGFloat = step
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = step
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct JournalRuledBackground: View {
    let lineColor: Color

    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var path = Path()
            var y: CGFloat = step
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            ctx.stroke(path, with: .color(lineColor), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct JournalIndexTabs: View {
    let activeChapter: JournalChapter
    let showHistory: Bool
    let palette: JournalPalette
    let onSelectChapter: ((JournalChapter) -> Void)?
    let onOpenHistory: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onSelectChapter {
                ForEach(JournalChapter.allCases, id: \.self) { ch in
                    let active = ch == activeChapter
                    tabButton(
                        title: ch.title,
                        color: ch.tabColor(in: palette),
                        active: active
                    ) {
                        onSelectChapter(ch)
                    }
                }
            }
            if showHistory, let onOpenHistory {
                tabButton(title: "历史", color: palette.cover, active: false, action: onOpenHistory)
            }
        }
    }

    private func tabButton(title: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                ForEach(Array(title), id: \.self) { ch in
                    Text(String(ch))
                        .font(DS.font(11.5, .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: active ? DS.s(30) : DS.s(26))
            .padding(.vertical, 9)
            .background(color.opacity(active ? 1.0 : 0.80), in: UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 8,
                topTrailingRadius: 8
            ))
            .shadow(color: .black.opacity(active ? 0.18 : 0.10), radius: 3, x: 2, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 实体橡皮印章、纸卡片、和纸便利贴、进度条

public struct JournalStampBadge: View {
    public enum Tone { case pending, draft, done, neutral }

    let text: String
    let tone: Tone
    let palette: JournalPalette
    var animationToken: Int = 0

    @State private var slamming = false

    public init(_ text: String, tone: Tone, palette: JournalPalette, animationToken: Int = 0) {
        self.text = text
        self.tone = tone
        self.palette = palette
        self.animationToken = animationToken
    }

    private var color: Color {
        switch tone {
        case .pending: palette.stampRed
        case .draft: palette.stampAmber
        case .done: palette.stampGreen
        case .neutral: palette.inkSecondary
        }
    }

    private var isDashed: Bool {
        tone == .pending || tone == .draft
    }

    public var body: some View {
        Text(text)
            .font(DS.font(12, .heavy))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(palette.paper.opacity(0.75), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        color,
                        style: StrokeStyle(lineWidth: isDashed ? 2 : 2.5, dash: isDashed ? [5, 3] : [])
                    )
            }
            .rotationEffect(.degrees(-6))
            .scaleEffect(slamming ? 1.38 : 1.0)
            .opacity(0.92)
            .onChange(of: animationToken) { _, _ in
                slamming = true
                withAnimation(.spring(response: 0.34, dampingFraction: 0.56)) {
                    slamming = false
                }
            }
    }
}

public struct JournalPaperCard<Content: View>: View {
    let palette: JournalPalette
    var accent: Color? = nil
    var paperclip: Bool = false
    var highlighted: Bool = false
    var padding: CGFloat = 13
    @ViewBuilder let content: Content

    public init(
        palette: JournalPalette,
        accent: Color? = nil,
        paperclip: Bool = false,
        highlighted: Bool = false,
        padding: CGFloat = 13,
        @ViewBuilder content: () -> Content
    ) {
        self.palette = palette
        self.accent = accent
        self.paperclip = paperclip
        self.highlighted = highlighted
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let accent {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3.5)
            }
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(highlighted ? palette.stickyFill : palette.paperCard)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(highlighted ? palette.stickyBorder : palette.borderStrong)
        }
        .overlay(alignment: .topTrailing) {
            if paperclip {
                Image(systemName: "paperclip")
                    .font(DS.font(12, .semibold))
                    .foregroundStyle(palette.inkTertiary)
                    .rotationEffect(.degrees(24))
                    .padding(.top, -5)
                    .padding(.trailing, 10)
            }
        }
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }
}

public struct JournalStickyNote<Content: View>: View {
    let palette: JournalPalette
    @ViewBuilder let content: Content

    public init(palette: JournalPalette, @ViewBuilder content: () -> Content) {
        self.palette = palette
        self.content = content()
    }

    public var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                palette.stickyFill,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 4,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12
                )
                .strokeBorder(palette.stickyBorder)
            }
            .shadow(color: .black.opacity(0.06), radius: 5, x: 1, y: 3)
            .rotationEffect(.degrees(-0.35))
    }
}

public struct JournalProgressBar: View {
    let recorded: Double
    let draftNormal: Double
    let draftOvertime: Double
    let target: Double
    let palette: JournalPalette

    public init(
        recorded: Double,
        draftNormal: Double,
        draftOvertime: Double,
        target: Double,
        palette: JournalPalette
    ) {
        self.recorded = recorded
        self.draftNormal = draftNormal
        self.draftOvertime = draftOvertime
        self.target = target
        self.palette = palette
    }

    public var body: some View {
        let total = recorded + draftNormal + draftOvertime
        let denom = max(target, total, 1)
        GeometryReader { geo in
            let w = geo.size.width
            let recW = max(0, min(w, w * CGFloat(recorded / denom)))
            let drW = max(0, min(w - recW, w * CGFloat(draftNormal / denom)))
            let otW = max(0, min(w - recW - drW, w * CGFloat(draftOvertime / denom)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.paperAlt)
                    .overlay { Capsule().strokeBorder(palette.border) }
                HStack(spacing: 0) {
                    if recW > 0 { Rectangle().fill(palette.stampGreen).frame(width: recW) }
                    if drW > 0 { Rectangle().fill(DS.brand).frame(width: drW) }
                    if otW > 0 { Rectangle().fill(palette.stampPurple).frame(width: otW) }
                }
                .clipShape(.capsule)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - 手账按钮样式

public struct JournalPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    public init(tint: Color) {
        self.tint = tint
    }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        JournalPrimaryBody(configuration: configuration, tint: tint)
    }
}

private struct JournalPrimaryBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(DS.font(13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: DS.s(30))
            .background(
                tint.opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.38),
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
    }
}

public struct JournalSecondaryButtonStyle: ButtonStyle {
    let palette: JournalPalette

    public init(palette: JournalPalette) {
        self.palette = palette
    }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        JournalSecondaryBody(configuration: configuration, palette: palette)
    }
}

private struct JournalSecondaryBody: View {
    let configuration: ButtonStyleConfiguration
    let palette: JournalPalette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(DS.font(12.5, .medium))
            .foregroundStyle(enabled ? palette.ink : palette.inkTertiary)
            .padding(.horizontal, 10)
            .frame(height: DS.s(28))
            .background(
                configuration.isPressed ? palette.border : (hovering ? palette.paperAlt : palette.paperCard),
                in: .rect(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(palette.borderStrong)
            }
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

public extension ButtonStyle where Self == JournalPrimaryButtonStyle {
    static func journalPrimary(tint: Color) -> JournalPrimaryButtonStyle {
        JournalPrimaryButtonStyle(tint: tint)
    }
}

public extension ButtonStyle where Self == JournalSecondaryButtonStyle {
    static func journalSecondary(_ palette: JournalPalette) -> JournalSecondaryButtonStyle {
        JournalSecondaryButtonStyle(palette: palette)
    }
}
