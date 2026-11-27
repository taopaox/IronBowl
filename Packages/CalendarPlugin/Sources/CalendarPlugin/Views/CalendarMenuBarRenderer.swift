import AppKit
import Foundation

enum CalendarAssets {
    static let logoImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "CalendarLogo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

private nonisolated final class CalendarMenuBarImageCache: @unchecked Sendable {
    struct StyledKey: Equatable {
        let style: CalendarMenuBarStyle
        let isDark: Bool
        let scale: CGFloat
        let logoID: ObjectIdentifier?
        let snapshot: CalendarMenuBarSnapshot
    }

    struct SegmentKey: Equatable {
        let isDark: Bool
        let scale: CGFloat
        let logoID: ObjectIdentifier?
        let segments: [MenuBarSegment]
    }

    static let shared = CalendarMenuBarImageCache()

    private let lock = NSLock()
    private let maxStyledEntries = 24
    private let maxSegmentEntries = 4
    private var styledEntries: [(key: StyledKey, image: NSImage)] = []
    private var segmentEntries: [(key: SegmentKey, image: NSImage)] = []

    func styledImage(for key: StyledKey) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return styledEntries.first { $0.key == key }?.image
    }

    func storeStyled(_ image: NSImage, for key: StyledKey) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = styledEntries.firstIndex(where: { $0.key == key }) {
            styledEntries[idx] = (key, image)
            return
        }
        if styledEntries.count >= maxStyledEntries {
            styledEntries.removeFirst()
        }
        styledEntries.append((key, image))
    }

    func segmentImage(for key: SegmentKey) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return segmentEntries.first { $0.key == key }?.image
    }

    func storeSegment(_ image: NSImage, for key: SegmentKey) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = segmentEntries.firstIndex(where: { $0.key == key }) {
            segmentEntries[idx] = (key, image)
            return
        }
        if segmentEntries.count >= maxSegmentEntries {
            segmentEntries.removeFirst()
        }
        segmentEntries.append((key, image))
    }
}

/// 菜单栏日历图像渲染器：支持 20 套可选视觉风格以及兼容旧版 `[MenuBarSegment]` 渲染接口，
/// 离线绘制为固定高度 `22pt` 的 Retina `NSImage`，避免 `MenuBarExtra` 动态文本插值在 macOS 上截断或闪烁。
public enum CalendarMenuBarRenderer {
    public static let barHeight: CGFloat = 22

    // MARK: - 颜色与字体辅助

    private struct Palette {
        let isDark: Bool
        let fg: NSColor
        let fg2: NSColor
        let fg3: NSColor
        let amber: NSColor
        let sky: NSColor
        let green: NSColor
        let rose: NSColor
        let purple: NSColor
        let divider: NSColor
        let pillBg: NSColor
        let pillBorder: NSColor

        init(isDark: Bool) {
            self.isDark = isDark
            if isDark {
                fg = srgb(0xF8FAFC)
                fg2 = srgb(0xF8FAFC, 0.74)
                fg3 = srgb(0xF8FAFC, 0.50)
                amber = srgb(0xFBBF24)
                sky = srgb(0x38BDF8)
                green = srgb(0x34D399)
                rose = srgb(0xFB7185)
                purple = srgb(0xC084FC)
                divider = srgb(0xFFFFFF, 0.22)
                pillBg = srgb(0xFFFFFF, 0.12)
                pillBorder = srgb(0xFFFFFF, 0.22)
            } else {
                fg = srgb(0x0F172A)
                fg2 = srgb(0x0F172A, 0.72)
                fg3 = srgb(0x0F172A, 0.48)
                amber = srgb(0xB45309)
                sky = srgb(0x0369A1)
                green = srgb(0x047857)
                rose = srgb(0xBE123C)
                purple = srgb(0x7E22CE)
                divider = srgb(0x0F172A, 0.18)
                pillBg = srgb(0x0F172A, 0.08)
                pillBorder = srgb(0x0F172A, 0.15)
            }
        }
    }

    private static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.rounded),
           let rounded = NSFont(descriptor: desc, size: size) {
            return rounded
        }
        return base
    }

    private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let candidateName = weight >= .semibold ? "Songti SC Bold" : "Songti SC"
        if let song = NSFont(name: candidateName, size: size) {
            return song
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.serif),
           let serif = NSFont(descriptor: desc, size: size) {
            return serif
        }
        return base
    }

    private static func symbolImage(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> (NSImage, NSSize) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            ?? NSImage())
            .withSymbolConfiguration(config) ?? NSImage()
        let raw = image.size
        let size = (raw.width > 0 && raw.height > 0) ? raw : NSSize(width: ceil(pointSize), height: ceil(pointSize))
        return (image, size)
    }

    private static func attr(_ string: String, font: NSFont, color: NSColor, kern: CGFloat? = nil) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if let kern {
            attrs[.kern] = kern
        }
        return NSAttributedString(string: string, attributes: attrs)
    }

    // MARK: - 原子绘制项

    private enum Atom {
        case image(NSImage, NSSize, yOffset: CGFloat)
        case text(NSAttributedString, NSSize, yOffset: CGFloat)
        case stack(top: NSAttributedString, bottom: NSAttributedString, width: CGFloat, spacing: CGFloat)
        case divider(height: CGFloat, color: NSColor)
        case dot(diameter: CGFloat, color: NSColor)
        case tagBox(text: NSAttributedString, bg: NSColor, border: NSColor?, cornerRadius: CGFloat, width: CGFloat, height: CGFloat)
        case tearOffTile(monthText: String, dayText: String)
        case vermilionSeal(text: String)
        case analogWatch(hour24: Int, minute: Int, second: Int, showSeconds: Bool, isDark: Bool)
        case spacer(CGFloat)

        var width: CGFloat {
            switch self {
            case .image(_, let size, _): ceil(size.width)
            case .text(_, let size, _): ceil(size.width)
            case .stack(_, _, let width, _): ceil(width)
            case .divider: 1
            case .dot(let d, _): d
            case .tagBox(_, _, _, _, let w, _): w
            case .tearOffTile: 19
            case .vermilionSeal: 18
            case .analogWatch: 19
            case .spacer(let w): w
            }
        }

        func draw(at x: CGFloat, barHeight: CGFloat) {
            switch self {
            case .image(let img, let size, let yOffset):
                let y = ((barHeight - size.height) / 2 + yOffset).rounded(.toNearestOrAwayFromZero)
                img.draw(in: NSRect(x: x, y: y, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
            case .text(let a, let size, let yOffset):
                let y = (barHeight - size.height) / 2 + yOffset
                a.draw(at: NSPoint(x: x, y: y))
            case .stack(let top, let bottom, _, let spacing):
                let topSize = top.size()
                let botSize = bottom.size()
                let totalH = topSize.height + spacing + botSize.height
                let baseY = (barHeight - totalH) / 2
                bottom.draw(at: NSPoint(x: x, y: baseY))
                top.draw(at: NSPoint(x: x, y: baseY + botSize.height + spacing))
            case .divider(let h, let color):
                color.setFill()
                NSRect(x: x, y: (barHeight - h) / 2, width: 1, height: h).fill()
            case .dot(let d, let color):
                color.setFill()
                let y = (barHeight - d) / 2
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
            case .tagBox(let a, let bg, let border, let cornerRadius, let w, let h):
                let rect = NSRect(x: x, y: (barHeight - h) / 2, width: w, height: h)
                let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                bg.setFill()
                path.fill()
                if let border {
                    border.setStroke()
                    path.lineWidth = 0.75
                    path.stroke()
                }
                let ts = a.size()
                a.draw(at: NSPoint(x: x + (w - ts.width) / 2, y: rect.minY + (h - ts.height) / 2))
            case .tearOffTile(let monthText, let dayText):
                drawTearOffTile(at: x, barHeight: barHeight, monthText: monthText, dayText: dayText)
            case .vermilionSeal(let text):
                drawVermilionSeal(at: x, barHeight: barHeight, text: text)
            case .analogWatch(let h24, let m, let s, let showSeconds, let isDark):
                drawAnalogWatch(at: x, barHeight: barHeight, hour24: h24, minute: m, second: s, showSeconds: showSeconds, isDark: isDark)
            case .spacer:
                break
            }
        }
    }

    private static func textAtom(_ string: String, font: NSFont, color: NSColor, yOffset: CGFloat = 0, kern: CGFloat? = nil) -> Atom {
        let a = attr(string, font: font, color: color, kern: kern)
        return .text(a, a.size(), yOffset: yOffset)
    }

    private static func stackAtom(
        top: String,
        topFont: NSFont,
        topColor: NSColor,
        bottom: String,
        bottomFont: NSFont,
        bottomColor: NSColor,
        spacing: CGFloat = -1
    ) -> Atom {
        let tAttr = attr(top, font: topFont, color: topColor)
        let bAttr = attr(bottom, font: bottomFont, color: bottomColor)
        let w = ceil(max(tAttr.size().width, bAttr.size().width))
        return .stack(top: tAttr, bottom: bAttr, width: w, spacing: spacing)
    }

    private static func holidayBadgeAtom(_ badge: String?, compact: Bool = false) -> Atom? {
        guard let badge, !badge.isEmpty else { return nil }
        let isHoliday = badge == "休"
        let size: CGFloat = compact ? 12.5 : 14
        let font = NSFont.systemFont(ofSize: compact ? 8 : 9, weight: .bold)
        let bg = isHoliday ? srgb(0xEF4444) : srgb(0xF59E0B)
        let fg: NSColor = isHoliday ? .white : srgb(0x111827)
        return .tagBox(
            text: attr(badge, font: font, color: fg),
            bg: bg,
            border: nil,
            cornerRadius: 3.5,
            width: size,
            height: size
        )
    }

    private static func logoAtom(resolvedLogo: NSImage?, height: CGFloat, color: NSColor) -> Atom {
        if let resolvedLogo {
            let raw = resolvedLogo.size
            let width = (raw.height > 0 && raw.width > 0) ? ceil(height * (raw.width / raw.height)) : height
            return .image(resolvedLogo, NSSize(width: width, height: height), yOffset: 0)
        }
        let (sym, sz) = symbolImage("calendar", pointSize: height - 2, weight: .medium, color: color)
        return .image(sym, sz, yOffset: 0)
    }

    // MARK: - 特制图形绘制

    private static func drawTearOffTile(at x: CGFloat, barHeight: CGFloat, monthText: String, dayText: String) {
        let size: CGFloat = 19
        let y = ((barHeight - size) / 2).rounded(.toNearestOrAwayFromZero)
        let rect = NSRect(x: x, y: y, width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        let outer = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        outer.addClip()

        NSColor.white.setFill()
        rect.fill()

        let headerH: CGFloat = 6.2
        let headerRect = NSRect(x: x, y: y + size - headerH, width: size, height: headerH)
        srgb(0xEF4444).setFill()
        headerRect.fill()

        let mAttr = attr(monthText, font: NSFont.systemFont(ofSize: 5.0, weight: .bold), color: .white)
        let ms = mAttr.size()
        mAttr.draw(at: NSPoint(x: x + (size - ms.width) / 2, y: headerRect.minY + (headerH - ms.height) / 2))

        let dAttr = attr(dayText, font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .heavy), color: srgb(0x0F172A))
        let ds = dAttr.size()
        let bodyH = size - headerH
        dAttr.draw(at: NSPoint(x: x + (size - ds.width) / 2, y: y + (bodyH - ds.height) / 2 - 0.5))

        NSGraphicsContext.restoreGraphicsState()

        srgb(0x0F172A, 0.18).setStroke()
        outer.lineWidth = 0.6
        outer.stroke()
    }

    private static func drawVermilionSeal(at x: CGFloat, barHeight: CGFloat, text: String) {
        let size: CGFloat = 18
        let y = ((barHeight - size) / 2).rounded(.toNearestOrAwayFromZero)
        let rect = NSRect(x: x, y: y, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        srgb(0xC8251E).setFill()
        path.fill()

        srgb(0xFECACA, 0.45).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        let fontSize: CGFloat = text.count >= 2 ? 7.6 : 10.5
        let tAttr = attr(text, font: serifFont(size: fontSize, weight: .bold), color: srgb(0xFEF2F2))
        let ts = tAttr.size()
        tAttr.draw(at: NSPoint(x: x + (size - ts.width) / 2, y: y + (size - ts.height) / 2))
    }

    private static func drawAnalogWatch(
        at x: CGFloat,
        barHeight: CGFloat,
        hour24: Int,
        minute: Int,
        second: Int,
        showSeconds: Bool,
        isDark: Bool
    ) {
        let size: CGFloat = 19
        let y = ((barHeight - size) / 2).rounded(.toNearestOrAwayFromZero)
        let cx = x + size / 2
        let cy = y + size / 2
        let radius: CGFloat = 8.4

        let faceBg = isDark ? srgb(0xFFFFFF, 0.10) : srgb(0x0F172A, 0.06)
        let stroke = isDark ? srgb(0xF8FAFC) : srgb(0x0F172A)

        let circle = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        faceBg.setFill()
        circle.fill()
        stroke.setStroke()
        circle.lineWidth = 1.25
        circle.stroke()

        // AppKit 坐标系原点在左下角，12 点方向为 +Y：x = cx + len * sin(theta), y = cy + len * cos(theta)
        let hourAngle = ((Double(hour24 % 12) + Double(minute) / 60.0) * 30.0) * .pi / 180.0
        let minAngle = (Double(minute) * 6.0 + Double(second) * 0.1) * .pi / 180.0
        let secAngle = (Double(second) * 6.0) * .pi / 180.0

        func drawHand(angle: Double, length: CGFloat, width: CGFloat, color: NSColor, tail: CGFloat = 0) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: cx - tail * sin(angle), y: cy - tail * cos(angle)))
            p.line(to: NSPoint(x: cx + length * sin(angle), y: cy + length * cos(angle)))
            p.lineWidth = width
            p.lineCapStyle = .round
            color.setStroke()
            p.stroke()
        }

        drawHand(angle: hourAngle, length: 4.5, width: 1.5, color: stroke)
        drawHand(angle: minAngle, length: 6.4, width: 1.15, color: stroke)
        if showSeconds {
            drawHand(angle: secAngle, length: 7.0, width: 0.75, color: srgb(0xEF4444), tail: 1.5)
        }

        let centerDot = NSBezierPath(ovalIn: NSRect(x: cx - 1.15, y: cy - 1.15, width: 2.3, height: 2.3))
        srgb(0xEF4444).setFill()
        centerDot.fill()
    }

    // MARK: - 布局容器配置

    private enum ContainerStyle {
        case none
        case glassPill(fill: NSColor, border: NSColor, topHighlight: NSColor?)
        case roundedCapsule(fill: NSColor, border: NSColor?, cornerRadius: CGFloat, bottomAccentColors: [NSColor]?)
        case hudBrackets(fill: NSColor, barColor: NSColor)
        case weatherAura(colors: [NSColor], border: NSColor)
        case daylightTrack(progress: Double)
        case splitRibbon(leftCount: Int, leftColors: [NSColor], rightFill: NSColor, border: NSColor)
    }

    private struct LayoutPlan {
        let atoms: [Atom]
        let gap: CGFloat
        let paddingX: CGFloat
        let container: ContainerStyle
        let isTemplate: Bool
        let useDarkFallback: Bool
    }

    // MARK: - 公开 API（20 套风格）

    public static func renderImage(
        snapshot: CalendarMenuBarSnapshot,
        style: CalendarMenuBarStyle,
        logoImage: NSImage? = nil,
        isDark: Bool = true,
        scale: CGFloat? = nil
    ) -> NSImage {
        let resolvedScale = max(1.0, scale ?? max(2.0, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0))
        let resolvedLogo = logoImage ?? CalendarAssets.logoImage
        let cacheKey = CalendarMenuBarImageCache.StyledKey(
            style: style,
            isDark: isDark,
            scale: resolvedScale,
            logoID: resolvedLogo.map(ObjectIdentifier.init),
            snapshot: snapshot
        )
        if let cached = CalendarMenuBarImageCache.shared.styledImage(for: cacheKey) {
            return cached
        }
        let palette = Palette(isDark: isDark)

        guard snapshot.hasAnyContent else {
            let fallback = renderFallbackSymbol(isDark: isDark, scale: resolvedScale)
            CalendarMenuBarImageCache.shared.storeStyled(fallback, for: cacheKey)
            return fallback
        }

        let plan = buildPlan(
            snapshot: snapshot,
            style: style,
            palette: palette,
            resolvedLogo: resolvedLogo
        )

        var contentWidth: CGFloat = 0
        for (i, atom) in plan.atoms.enumerated() {
            if i > 0 { contentWidth += plan.gap }
            contentWidth += atom.width
        }

        let totalWidth = max(20, ceil(contentWidth + plan.paddingX * 2))
        let logicalSize = NSSize(width: totalWidth, height: barHeight)

        let image = renderBitmap(logicalSize: logicalSize, scale: resolvedScale, isTemplate: plan.isTemplate) {
            drawContainer(plan.container, atoms: plan.atoms, gap: plan.gap, paddingX: plan.paddingX, size: logicalSize)

            var x = plan.paddingX
            for (i, atom) in plan.atoms.enumerated() {
                if i > 0 { x += plan.gap }
                atom.draw(at: x, barHeight: barHeight)
                x += atom.width
            }
        }
        CalendarMenuBarImageCache.shared.storeStyled(image, for: cacheKey)
        return image
    }

    // MARK: - 20 套风格布局生成器

    private static func buildPlan(
        snapshot s: CalendarMenuBarSnapshot,
        style: CalendarMenuBarStyle,
        palette p: Palette,
        resolvedLogo: NSImage?
    ) -> LayoutPlan {
        let hasColorLogo = s.showLogo && resolvedLogo != nil

        switch style {
        case .microDashboard:
            // #01 双行微缩仪表卡
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 17, color: p.fg)) }
            var cols: [Atom] = []
            if s.hasWeatherPart {
                let top = s.weatherText ?? "空气"
                let bot = [s.temperatureText, s.aqi.map { "AQI \($0)" }].compactMap { $0 }.joined(separator: " ")
                cols.append(stackAtom(
                    top: top, topFont: .monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold), topColor: p.amber,
                    bottom: bot, bottomFont: .monospacedDigitSystemFont(ofSize: 10.0, weight: .bold), bottomColor: p.fg
                ))
            }
            if s.hasDatePart {
                let topParts = [s.lunarText, s.weekdayShort].compactMap { $0 }
                let top = topParts.isEmpty ? "公历" : topParts.joined(separator: " ")
                let bot = s.solarText ?? s.weekdayShort ?? s.lunarText ?? ""
                if !bot.isEmpty {
                    cols.append(stackAtom(
                        top: top, topFont: .monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold), topColor: p.sky,
                        bottom: bot, bottomFont: .monospacedDigitSystemFont(ofSize: 10.0, weight: .bold), bottomColor: p.fg
                    ))
                }
                if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) {
                    cols.append(badge)
                }
            }
            if s.timeEnabled {
                let top = s.timeUse24Hour ? "本地时间" : s.timePeriodEN
                cols.append(stackAtom(
                    top: top, topFont: .monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold), topColor: p.green,
                    bottom: s.timeFull, bottomFont: .monospacedDigitSystemFont(ofSize: 10.0, weight: .bold), bottomColor: p.fg
                ))
            }
            for (idx, col) in cols.enumerated() {
                if idx > 0 { atoms.append(.divider(height: 11, color: p.divider)) }
                atoms.append(col)
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .nativeMinimal:
            // #02 原生 macOS 极简排印（无 Logo 且无彩色角标时保持纯正模板图）
            let isTemplate = !hasColorLogo && s.holidayBadge == nil
            let primary = isTemplate ? NSColor.black : p.fg
            let secondary = isTemplate ? NSColor.black.withAlphaComponent(0.75) : p.fg2
            let dotColor = isTemplate ? NSColor.black.withAlphaComponent(0.45) : p.fg3
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 16, color: primary)) }
            var groups: [[Atom]] = []
            if s.hasWeatherPart {
                var wGroup: [Atom] = []
                if let sym = s.weatherSymbol {
                    let (img, sz) = symbolImage(sym, pointSize: 12.5, weight: .medium, color: secondary)
                    wGroup.append(.image(img, sz, yOffset: 0))
                }
                if let temp = s.temperatureText {
                    wGroup.append(textAtom(temp, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular), color: secondary))
                }
                if let aqi = s.aqi {
                    let cat = s.aqiCategory ?? ""
                    wGroup.append(textAtom("\(cat)\(aqi)", font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), color: secondary))
                }
                if !wGroup.isEmpty { groups.append(wGroup) }
            }
            let dParts = [s.solarText, s.weekdayShort].compactMap { $0 }
            if !dParts.isEmpty {
                groups.append([textAtom(dParts.joined(separator: " "), font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular), color: primary)])
            }
            if let lunar = s.lunarText {
                groups.append([textAtom(lunar, font: .systemFont(ofSize: 11.5, weight: .regular), color: secondary)])
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) {
                groups.append([badge])
            }
            if s.timeEnabled {
                var tGroup: [Atom] = []
                if s.timeShowIcon {
                    let (img, sz) = symbolImage("clock", pointSize: 12, weight: .medium, color: primary)
                    tGroup.append(.image(img, sz, yOffset: 0))
                }
                tGroup.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), color: primary))
                groups.append(tGroup)
            }
            for (idx, grp) in groups.enumerated() {
                if idx > 0 { atoms.append(textAtom("·", font: .systemFont(ofSize: 11, weight: .medium), color: dotColor)) }
                atoms.append(contentsOf: grp)
            }
            return LayoutPlan(atoms: atoms, gap: 4, paddingX: 2, container: .none, isTemplate: isTemplate, useDarkFallback: p.isDark)

        case .tearOffTile:
            // #03 迷你撕页日历徽章
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 16, color: p.fg)) }
            if s.solarText != nil || (!s.timeEnabled && !s.hasWeatherPart) {
                atoms.append(.tearOffTile(monthText: "\(s.month)月", dayText: "\(s.day)"))
            }
            let metaTop = [s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " · ")
            let metaBot = [s.weatherText.flatMap { wt in s.temperatureText.map { "\(wt) \($0)" } } ?? s.temperatureText,
                           s.aqi.map { "AQI \($0)" }].compactMap { $0 }.joined(separator: " ")
            if !metaTop.isEmpty || !metaBot.isEmpty {
                if !metaTop.isEmpty && !metaBot.isEmpty {
                    atoms.append(stackAtom(
                        top: metaTop, topFont: .systemFont(ofSize: 8.0, weight: .medium), topColor: p.fg2,
                        bottom: metaBot, bottomFont: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), bottomColor: p.fg
                    ))
                } else {
                    atoms.append(textAtom(metaTop.isEmpty ? metaBot : metaTop, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg2))
                }
            }
            if let badge = holidayBadgeAtom(s.holidayBadge) { atoms.append(badge) }
            if s.timeEnabled {
                atoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), color: p.fg))
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .liquidGlass:
            // #04 液态玻璃分段胶囊
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: p.fg)) }
            var segs: [[Atom]] = []
            if s.hasWeatherPart {
                var w: [Atom] = []
                if let sym = s.weatherSymbol {
                    let (img, sz) = symbolImage(sym, pointSize: 11, weight: .semibold, color: p.amber)
                    w.append(.image(img, sz, yOffset: 0))
                }
                if let t = s.temperatureText {
                    w.append(textAtom(t, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg))
                }
                if let aqi = s.aqi {
                    w.append(textAtom("\(aqi)", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.green))
                }
                segs.append(w)
            }
            let d = [s.solarSlash, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty || s.holidayBadge != nil {
                var dAtoms: [Atom] = []
                if !d.isEmpty {
                    dAtoms.append(textAtom(d, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg))
                }
                if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { dAtoms.append(badge) }
                segs.append(dAtoms)
            }
            if s.timeEnabled {
                segs.append([textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold), color: p.fg)])
            }
            for (idx, seg) in segs.enumerated() {
                if idx > 0 { atoms.append(.divider(height: 12, color: p.divider)) }
                atoms.append(contentsOf: seg)
            }
            let fill = p.isDark ? srgb(0xFFFFFF, 0.13) : srgb(0xFFFFFF, 0.68)
            let border = p.isDark ? srgb(0xFFFFFF, 0.24) : srgb(0x0F172A, 0.14)
            let highlight = p.isDark ? srgb(0xFFFFFF, 0.28) : srgb(0xFFFFFF, 0.90)
            return LayoutPlan(atoms: atoms, gap: 4.5, paddingX: 8, container: .glassPill(fill: fill, border: border, topHighlight: highlight), isTemplate: false, useDarkFallback: p.isDark)

        case .vermilionSeal:
            // #05 东方朱砂印章历
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 15, color: p.fg)) }
            let sealChar = s.holidayBadge ?? s.lunarDay ?? "\(s.day)"
            atoms.append(.vermilionSeal(text: sealChar))
            if let lunar = s.lunarText {
                atoms.append(textAtom(lunar, font: serifFont(size: 12, weight: .semibold), color: p.fg))
            }
            let subParts = [s.solarText, s.weekdayShort, s.temperatureText.map { "\(s.weatherText ?? "")\($0)" }, s.aqiCategory].compactMap { $0 }
            if !subParts.isEmpty {
                atoms.append(textAtom(subParts.joined(separator: " "), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: p.fg2))
            }
            if s.timeEnabled {
                atoms.append(.divider(height: 10, color: srgb(0xC8251E, 0.65)))
                atoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), color: p.fg))
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .swissChrono:
            // #06 瑞士精密计时器
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 15, color: p.fg)) }
            atoms.append(.dot(diameter: 6, color: srgb(0xEF4444)))
            if let enDay = s.weekdayEN {
                let tagAttr = attr(enDay, font: .systemFont(ofSize: 8.5, weight: .heavy), color: p.isDark ? srgb(0x0F172A) : srgb(0xF8FAFC), kern: 0.5)
                atoms.append(.tagBox(text: tagAttr, bg: p.fg, border: nil, cornerRadius: 3, width: ceil(tagAttr.size().width) + 7, height: 14))
            }
            let meta = [s.solarDot, s.lunarText, s.temperatureText, s.aqi.map { "AQI\($0)" }].compactMap { $0 }.joined(separator: " · ")
            if !meta.isEmpty {
                atoms.append(textAtom(meta, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg2))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                if s.timeShowPeriod, let per = s.timePeriod {
                    atoms.append(textAtom(per == "上午" ? "AM" : "PM", font: .systemFont(ofSize: 9.5, weight: .semibold), color: p.fg2))
                }
                atoms.append(textAtom(s.timeHM, font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold), color: p.fg, kern: -0.3))
                if s.timeShowSeconds {
                    atoms.append(textAtom(":\(s.timeSeconds)", font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold), color: srgb(0xEF4444)))
                }
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 3, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .splitRibbon:
            // #07 双色拼接胶片条
            var leftAtoms: [Atom] = []
            if s.showLogo { leftAtoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: .white)) }
            if s.weatherEnabled {
                if let sym = s.weatherSymbol {
                    let (img, sz) = symbolImage(sym, pointSize: 11, weight: .bold, color: .white)
                    leftAtoms.append(.image(img, sz, yOffset: 0))
                }
                if let t = s.temperatureText {
                    leftAtoms.append(textAtom(t, font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold), color: .white))
                }
                if let aqi = s.aqi {
                    leftAtoms.append(textAtom("\(aqi)", font: .monospacedDigitSystemFont(ofSize: 10, weight: .bold), color: .white.withAlphaComponent(0.92)))
                }
            }
            var rightAtoms: [Atom] = []
            let d = [s.solarText, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                rightAtoms.append(textAtom(d, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: p.fg))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { rightAtoms.append(badge) }
            if s.timeEnabled {
                rightAtoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold), color: p.fg))
            }
            let atoms = leftAtoms + rightAtoms
            let rightFill = p.isDark ? srgb(0x0F172A, 0.72) : srgb(0xFFFFFF, 0.88)
            return LayoutPlan(
                atoms: atoms,
                gap: 5,
                paddingX: 7,
                container: .splitRibbon(
                    leftCount: leftAtoms.count,
                    leftColors: [srgb(0xF59E0B), srgb(0xEA580C)],
                    rightFill: rightFill,
                    border: p.pillBorder
                ),
                isTemplate: false,
                useDarkFallback: p.isDark
            )

        case .daylightTrack:
            // #08 日晷昼夜进度条
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: p.fg)) }
            if let sym = s.weatherSymbol {
                let (img, sz) = symbolImage(sym, pointSize: 11, weight: .semibold, color: p.amber)
                atoms.append(.image(img, sz, yOffset: 1))
            }
            if let t = s.temperatureText {
                atoms.append(textAtom(t, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), color: p.amber, yOffset: 1))
            }
            if let aqi = s.aqi {
                atoms.append(textAtom("AQI \(aqi)", font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: p.green, yOffset: 1))
            }
            let d = [s.solarSlash, s.weekdayShort].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                atoms.append(textAtom(d, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg, yOffset: 1))
            }
            if let lunar = s.lunarText {
                atoms.append(textAtom(lunar, font: .systemFont(ofSize: 11, weight: .regular), color: p.fg2, yOffset: 1))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                atoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold), color: p.fg, yOffset: 1))
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 4, container: .daylightTrack(progress: s.dayProgress), isTemplate: false, useDarkFallback: p.isDark)

        case .casioLCD:
            // #09 复古卡西欧 LCD 数显
            let lcdFg = p.isDark ? srgb(0xBEF264) : srgb(0x1A2417)
            let lcdBg = p.isDark ? srgb(0x222922) : srgb(0xCBD5BF)
            let lcdBorder = p.isDark ? srgb(0x3F4E3D) : srgb(0x94A38A)
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 13, color: lcdFg)) }
            if let enDay = s.weekdayEN {
                let tagAttr = attr(enDay, font: .monospacedSystemFont(ofSize: 8.5, weight: .bold), color: lcdFg)
                atoms.append(.tagBox(text: tagAttr, bg: .clear, border: lcdFg.withAlphaComponent(0.75), cornerRadius: 2, width: ceil(tagAttr.size().width) + 6, height: 13))
            }
            let info = [s.temperatureText.map { "\($0)C" }, s.aqi.map { "AQ\($0)" }, s.solarDash, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !info.isEmpty {
                atoms.append(textAtom(info, font: .monospacedSystemFont(ofSize: 10.5, weight: .semibold), color: lcdFg.withAlphaComponent(0.9)))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                let prefix = s.timeShowPeriod ? (s.hour24 < 12 ? "AM " : "PM ") : ""
                atoms.append(textAtom("\(prefix)\(s.timeFull)", font: .monospacedSystemFont(ofSize: 11.5, weight: .bold), color: lcdFg))
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 7, container: .roundedCapsule(fill: lcdBg, border: lcdBorder, cornerRadius: 4, bottomAccentColors: nil), isTemplate: false, useDarkFallback: p.isDark)

        case .softClay:
            // #10 软萌毛毡云朵伴侣
            let pillFill = p.isDark ? srgb(0xFB923C, 0.18) : srgb(0xFFF7ED, 0.92)
            let pillBorder = p.isDark ? srgb(0xFB923C, 0.38) : srgb(0xF97316, 0.32)
            let fgMain = p.isDark ? p.fg : srgb(0x7C2D12)
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 16, color: fgMain)) }
            if let sym = s.weatherSymbol {
                let (img, sz) = symbolImage(sym, pointSize: 11.5, weight: .semibold, color: srgb(0xF59E0B))
                atoms.append(.image(img, sz, yOffset: 0))
            }
            if let t = s.temperatureText {
                atoms.append(textAtom(t, font: roundedFont(size: 11.5, weight: .semibold), color: fgMain))
            }
            if let aqi = s.aqi {
                let tagText = "\(s.aqiCategory ?? "AQI") \(aqi)"
                let tAttr = attr(tagText, font: roundedFont(size: 9.5, weight: .semibold), color: p.isDark ? srgb(0xFDBA74) : srgb(0xC2410C))
                atoms.append(.tagBox(text: tAttr, bg: srgb(0xF97316, 0.18), border: nil, cornerRadius: 7, width: ceil(tAttr.size().width) + 9, height: 14.5))
            }
            let d = [s.solarText, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                atoms.append(textAtom(d, font: roundedFont(size: 11.5, weight: .medium), color: fgMain))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                atoms.append(textAtom(s.timeFormatted, font: roundedFont(size: 12, weight: .bold), color: fgMain))
            }
            return LayoutPlan(atoms: atoms, gap: 4.5, paddingX: 7, container: .roundedCapsule(fill: pillFill, border: pillBorder, cornerRadius: 11, bottomAccentColors: nil), isTemplate: false, useDarkFallback: p.isDark)

        case .terminalStream:
            // #11 极客终端语法流
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: p.fg)) }
            var chunks: [Atom] = []
            if let t = s.temperatureText {
                chunks.append(textAtom("☀\(t)", font: .monospacedSystemFont(ofSize: 11, weight: .semibold), color: p.amber))
            }
            if let aqi = s.aqi {
                chunks.append(textAtom("●\(aqi)", font: .monospacedSystemFont(ofSize: 10.5, weight: .semibold), color: p.green))
            }
            let d = [s.solarDash, s.weekdayShort].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                chunks.append(textAtom(d, font: .monospacedSystemFont(ofSize: 11, weight: .medium), color: p.sky))
            }
            if let lunar = s.lunarText {
                chunks.append(textAtom(lunar, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: p.purple))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { chunks.append(badge) }
            if s.timeEnabled {
                let prefix = s.timeShowPeriod ? (s.hour24 < 12 ? "am:" : "pm:") : ""
                chunks.append(textAtom("\(prefix)\(s.timeFull)", font: .monospacedSystemFont(ofSize: 11.5, weight: .bold), color: p.fg))
            }
            for (idx, c) in chunks.enumerated() {
                if idx > 0 {
                    atoms.append(textAtom("│", font: .monospacedSystemFont(ofSize: 10.5, weight: .regular), color: p.fg3))
                }
                atoms.append(c)
            }
            return LayoutPlan(atoms: atoms, gap: 3.5, paddingX: 3, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .analogWatch:
            // #12 实时微缩模拟表盘
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 15, color: p.fg)) }
            atoms.append(.analogWatch(hour24: s.hour24, minute: s.minute, second: s.second, showSeconds: s.timeShowSeconds, isDark: p.isDark))
            let topLine = [s.solarText, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            let botLine = [
                s.timeEnabled ? s.timeFormatted : nil,
                s.temperatureText,
                s.aqi.map { "AQI \($0)" },
            ].compactMap { $0 }.joined(separator: " · ")
            if !topLine.isEmpty && !botLine.isEmpty {
                atoms.append(stackAtom(
                    top: topLine, topFont: .systemFont(ofSize: 8.2, weight: .medium), topColor: p.fg2,
                    bottom: botLine, bottomFont: .monospacedDigitSystemFont(ofSize: 10.2, weight: .semibold), bottomColor: p.fg
                ))
            } else if !topLine.isEmpty || !botLine.isEmpty {
                atoms.append(textAtom(topLine.isEmpty ? botLine : topLine, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), color: p.fg))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .weatherAura:
            // #13 气象光晕色温带
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 15, color: p.fg)) }
            if let sym = s.weatherSymbol {
                let (img, sz) = symbolImage(sym, pointSize: 11.5, weight: .semibold, color: p.amber)
                atoms.append(.image(img, sz, yOffset: 0))
            }
            if let t = s.temperatureText {
                let wt = s.weatherText.map { "\($0) \(t)" } ?? t
                atoms.append(textAtom(wt, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold), color: p.amber))
            }
            if let aqi = s.aqi {
                atoms.append(textAtom("AQI \(aqi)", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.green))
            }
            let d = [s.solarText, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                atoms.append(textAtom(d, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: p.fg))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                atoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 12, weight: .bold), color: p.fg))
            }
            let isRainyOrCold = (s.weatherSymbol?.contains("rain") == true) || (s.weatherSymbol?.contains("snow") == true) || (s.weatherSymbol?.contains("cloud") == true)
            let auraColors: [NSColor] = if isRainyOrCold {
                p.isDark
                    ? [srgb(0x38BDF8, 0.28), srgb(0x6366F1, 0.14), srgb(0xFFFFFF, 0.05)]
                    : [srgb(0x38BDF8, 0.28), srgb(0xE0F2FE, 0.72), srgb(0xFFFFFF, 0.80)]
            } else {
                p.isDark
                    ? [srgb(0xFBBF24, 0.28), srgb(0xF97316, 0.13), srgb(0xFFFFFF, 0.05)]
                    : [srgb(0xFBBF24, 0.30), srgb(0xFEF3C7, 0.72), srgb(0xFFFFFF, 0.80)]
            }
            let auraBorder = isRainyOrCold
                ? srgb(0x38BDF8, 0.30)
                : (p.isDark ? srgb(0xFBBF24, 0.30) : srgb(0xD97706, 0.26))
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 7, container: .weatherAura(colors: auraColors, border: auraBorder), isTemplate: false, useDarkFallback: p.isDark)

        case .editorialSerif:
            // #14 典雅报刊衬线体
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: p.fg)) }
            var segs: [Atom] = []
            let wStr = [s.temperatureText.map { "\(s.weatherText ?? "晴") \($0)" }, s.aqi.map { "空气 \($0)" }].compactMap { $0 }.joined(separator: " · ")
            if !wStr.isEmpty {
                segs.append(textAtom(wStr, font: serifFont(size: 11.5, weight: .regular), color: p.fg2))
            }
            let d = [s.solarDot, s.weekdayShort].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                segs.append(textAtom(d, font: serifFont(size: 12, weight: .semibold), color: p.fg, kern: 0.4))
            }
            if let lunar = s.lunarText {
                segs.append(textAtom(lunar, font: serifFont(size: 11.5, weight: .medium), color: p.amber))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { segs.append(badge) }
            if s.timeEnabled {
                segs.append(textAtom(s.timeFormatted, font: serifFont(size: 12.5, weight: .bold), color: p.fg, kern: 0.3))
            }
            for (idx, seg) in segs.enumerated() {
                if idx > 0 { atoms.append(.divider(height: 11, color: p.divider)) }
                atoms.append(seg)
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 3, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .avionicsHUD:
            // #15 航空座舱 HUD 遥测
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: p.fg)) }
            if s.hasWeatherPart {
                let lbl = (s.temperatureText != nil && s.aqi != nil) ? "WX/AQI" : (s.temperatureText != nil ? "TEMP" : "AQI")
                let val = [s.temperatureText.map { "\($0)C" }, s.aqi.map(String.init)].compactMap { $0 }.joined(separator: "/")
                atoms.append(stackAtom(
                    top: lbl, topFont: .monospacedSystemFont(ofSize: 6.5, weight: .bold), topColor: p.sky,
                    bottom: val, bottomFont: .monospacedSystemFont(ofSize: 9.5, weight: .bold), bottomColor: p.fg
                ))
            }
            if s.hasDatePart {
                let lbl = s.lunarText ?? "DATE"
                let val = [s.solarDash, s.weekdayEN].compactMap { $0 }.joined(separator: " ")
                let resolvedVal = val.isEmpty ? (s.lunarText ?? "DATE") : val
                atoms.append(stackAtom(
                    top: lbl, topFont: .monospacedSystemFont(ofSize: 6.5, weight: .bold), topColor: p.sky,
                    bottom: resolvedVal, bottomFont: .monospacedSystemFont(ofSize: 9.5, weight: .bold), bottomColor: p.fg
                ))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                let lbl = s.timeUse24Hour ? "LOCAL" : s.timePeriodEN
                atoms.append(stackAtom(
                    top: lbl, topFont: .monospacedSystemFont(ofSize: 6.5, weight: .bold), topColor: p.sky,
                    bottom: s.timeFull, bottomFont: .monospacedSystemFont(ofSize: 9.5, weight: .bold), bottomColor: p.fg
                ))
            }
            let hudFill = p.isDark ? srgb(0x06B6D4, 0.10) : srgb(0x0891B2, 0.10)
            let hudBar = p.isDark ? srgb(0x22D3EE) : srgb(0x0891B2)
            return LayoutPlan(atoms: atoms, gap: 7, paddingX: 7, container: .hudBrackets(fill: hudFill, barColor: hudBar), isTemplate: false, useDarkFallback: p.isDark)

        case .cyberNeon:
            // #16 赛博霓虹光边条
            let neonText = srgb(0xF8FAFC)
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: neonText)) }
            if let sym = s.weatherSymbol {
                let (img, sz) = symbolImage(sym, pointSize: 11, weight: .semibold, color: srgb(0xFBBF24))
                atoms.append(.image(img, sz, yOffset: 0.5))
            }
            if let t = s.temperatureText {
                atoms.append(textAtom(t, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), color: srgb(0xFBBF24), yOffset: 0.5))
            }
            if let aqi = s.aqi {
                atoms.append(textAtom("AQI\(aqi)", font: .monospacedSystemFont(ofSize: 10, weight: .semibold), color: srgb(0x4ADE80), yOffset: 0.5))
            }
            let d = [s.solarSlash, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                atoms.append(textAtom(d, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: neonText, yOffset: 0.5))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                let tm = s.timeShowPeriod ? "\(s.timePeriodEN) \(s.timeFull)" : s.timeFull
                atoms.append(textAtom(tm, font: .monospacedSystemFont(ofSize: 11.5, weight: .bold), color: srgb(0x67E8F9), yOffset: 0.5))
            }
            return LayoutPlan(
                atoms: atoms,
                gap: 5,
                paddingX: 8,
                container: .roundedCapsule(
                    fill: srgb(0x0F0C1E, 0.88),
                    border: srgb(0xA855F7, 0.45),
                    cornerRadius: 6,
                    bottomAccentColors: [srgb(0x06B6D4), srgb(0xA855F7), srgb(0xEC4899)]
                ),
                isTemplate: false,
                useDarkFallback: true
            )

        case .washiStationery:
            // #17 日式和纸手帐标
            let paperBg = p.isDark ? srgb(0xF5F0E6, 0.14) : srgb(0xF5F2EB)
            let paperBorder = p.isDark ? srgb(0xF5F0E6, 0.24) : srgb(0xD6D0C4)
            let paperFg = p.isDark ? p.fg : srgb(0x292524)
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 14, color: paperFg)) }
            if let t = s.temperatureText {
                let wStr = s.weatherText.map { "\($0) \(t)" } ?? t
                atoms.append(textAtom(wStr, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular), color: paperFg))
            }
            if let aqi = s.aqi {
                let aStr = "\(s.aqiCategory ?? "优") \(aqi)"
                let aAttr = attr(aStr, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), color: p.green)
                atoms.append(.tagBox(text: aAttr, bg: srgb(0x10B981, 0.16), border: nil, cornerRadius: 7, width: ceil(aAttr.size().width) + 8, height: 14))
            }
            if let solar = s.solarText {
                atoms.append(textAtom(solar, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), color: paperFg))
            }
            if let wk = s.weekdaySingle {
                let wAttr = attr(wk, font: .systemFont(ofSize: 9.5, weight: .bold), color: paperFg.withAlphaComponent(0.88))
                atoms.append(.tagBox(text: wAttr, bg: .clear, border: paperFg.withAlphaComponent(0.65), cornerRadius: 3, width: 14.5, height: 14.5))
            }
            if let lunar = s.lunarText {
                atoms.append(textAtom(lunar, font: .systemFont(ofSize: 11, weight: .regular), color: paperFg.withAlphaComponent(0.75)))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                atoms.append(textAtom(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), color: paperFg))
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 7, container: .roundedCapsule(fill: paperBg, border: paperBorder, cornerRadius: 5, bottomAccentColors: nil), isTemplate: false, useDarkFallback: p.isDark)

        case .notchCompact:
            // #18 极致省宽双层叠排
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 15, color: p.fg)) }
            let wTop = [s.temperatureText.map { "☀\($0)" }, s.aqi.map { "优\($0)" }].compactMap { $0 }.joined(separator: " ")
            let wBot = s.lunarText ?? ""
            if !wTop.isEmpty && !wBot.isEmpty {
                atoms.append(stackAtom(
                    top: wTop, topFont: .monospacedDigitSystemFont(ofSize: 8.0, weight: .semibold), topColor: p.fg2,
                    bottom: wBot, bottomFont: .systemFont(ofSize: 9.2, weight: .semibold), bottomColor: p.fg
                ))
            } else if !wTop.isEmpty || !wBot.isEmpty {
                atoms.append(textAtom(wTop.isEmpty ? wBot : wTop, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.fg))
            }
            let dTop = s.weekdayShort ?? ""
            let dBot = s.solarSlash ?? ""
            if !dTop.isEmpty && !dBot.isEmpty {
                atoms.append(stackAtom(
                    top: dTop, topFont: .systemFont(ofSize: 8.0, weight: .semibold), topColor: p.sky,
                    bottom: dBot, bottomFont: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), bottomColor: p.fg
                ))
            } else if !dTop.isEmpty || !dBot.isEmpty {
                atoms.append(textAtom(dTop.isEmpty ? dBot : dTop, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.fg))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                let prefix = s.timeShowPeriod ? (s.hour24 < 12 ? "上" : "下") : ""
                atoms.append(textAtom("\(prefix)\(s.timeFull)", font: .monospacedDigitSystemFont(ofSize: 13.5, weight: .bold), color: p.fg, kern: -0.3))
            }
            return LayoutPlan(atoms: atoms, gap: 4.5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .semanticChips:
            // #19 语义微胶囊群组
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 16, color: p.fg)) }
            if let t = s.temperatureText {
                let cAttr = attr("☀ \(t)", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.amber)
                atoms.append(.tagBox(text: cAttr, bg: srgb(0xF59E0B, 0.18), border: srgb(0xF59E0B, 0.34), cornerRadius: 5, width: ceil(cAttr.size().width) + 10, height: 18))
            }
            if let aqi = s.aqi {
                let cAttr = attr("\(aqi) \(s.aqiCategory ?? "优")", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.green)
                atoms.append(.tagBox(text: cAttr, bg: srgb(0x10B981, 0.16), border: srgb(0x10B981, 0.32), cornerRadius: 5, width: ceil(cAttr.size().width) + 10, height: 18))
            }
            let d = [s.solarText, s.weekdayShort, s.lunarText].compactMap { $0 }.joined(separator: " ")
            if !d.isEmpty {
                let dAttr = attr(d, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: p.fg)
                atoms.append(.tagBox(text: dAttr, bg: p.pillBg, border: p.pillBorder, cornerRadius: 5, width: ceil(dAttr.size().width) + 10, height: 18))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                let tAttr = attr(s.timeFormatted, font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold), color: .white)
                atoms.append(.tagBox(text: tAttr, bg: srgb(0xF97316), border: nil, cornerRadius: 5, width: ceil(tAttr.size().width) + 10, height: 18))
            }
            return LayoutPlan(atoms: atoms, gap: 3, paddingX: 1, container: .none, isTemplate: false, useDarkFallback: p.isDark)

        case .heroClock:
            // #20 呼吸大时钟 + 轻语副标
            var atoms: [Atom] = []
            if s.showLogo { atoms.append(logoAtom(resolvedLogo: resolvedLogo, height: 17, color: p.fg)) }
            let m1 = [s.solarText, s.weekdayShort].compactMap { $0 }.joined(separator: " ")
            let m2 = [s.lunarText, s.temperatureText.map { "\(s.weatherText ?? "")\($0)" }, s.aqiCategory].compactMap { $0 }.joined(separator: " · ")
            if !m1.isEmpty && !m2.isEmpty {
                atoms.append(stackAtom(
                    top: m1, topFont: .monospacedDigitSystemFont(ofSize: 8.2, weight: .medium), topColor: p.fg2,
                    bottom: m2, bottomFont: .systemFont(ofSize: 8.2, weight: .medium), bottomColor: p.fg3
                ))
            } else if !m1.isEmpty || !m2.isEmpty {
                atoms.append(textAtom(m1.isEmpty ? m2 : m1, font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), color: p.fg2))
            }
            if let badge = holidayBadgeAtom(s.holidayBadge, compact: true) { atoms.append(badge) }
            if s.timeEnabled {
                if s.timeShowPeriod, let per = s.timePeriod {
                    atoms.append(textAtom(per, font: .systemFont(ofSize: 9.5, weight: .medium), color: p.fg2))
                }
                atoms.append(textAtom(s.timeHM, font: .monospacedDigitSystemFont(ofSize: 15.5, weight: .bold), color: p.fg, kern: -0.4))
                if s.timeShowSeconds {
                    atoms.append(textAtom(":\(s.timeSeconds)", font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: p.fg2))
                }
            }
            return LayoutPlan(atoms: atoms, gap: 5, paddingX: 2, container: .none, isTemplate: false, useDarkFallback: p.isDark)
        }
    }

    // MARK: - 容器绘制

    private static func drawContainer(
        _ container: ContainerStyle,
        atoms: [Atom],
        gap: CGFloat,
        paddingX: CGFloat,
        size: NSSize
    ) {
        let fullRect = NSRect(origin: .zero, size: size)
        switch container {
        case .none:
            break
        case .glassPill(let fill, let border, let topHighlight):
            let pillRect = fullRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            fill.setFill()
            path.fill()
            border.setStroke()
            path.lineWidth = 0.9
            path.stroke()
            if let topHighlight {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: pillRect.height / 2, y: pillRect.maxY - 0.8))
                line.line(to: NSPoint(x: pillRect.maxX - pillRect.height / 2, y: pillRect.maxY - 0.8))
                topHighlight.setStroke()
                line.lineWidth = 0.75
                line.stroke()
            }
        case .roundedCapsule(let fill, let border, let cornerRadius, let bottomAccentColors):
            let pillRect = fullRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            fill.setFill()
            pillRect.fill()
            if let bottomAccentColors, !bottomAccentColors.isEmpty,
               let grad = NSGradient(colors: bottomAccentColors) {
                grad.draw(in: NSRect(x: 0, y: 0, width: size.width, height: 2.2), angle: 0)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let border {
                border.setStroke()
                path.lineWidth = 0.9
                path.stroke()
            }
        case .hudBrackets(let fill, let barColor):
            let rect = fullRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            fill.setFill()
            path.fill()
            barColor.setFill()
            NSRect(x: 0.5, y: 1, width: 2, height: size.height - 2).fill()
            NSRect(x: size.width - 2.5, y: 1, width: 2, height: size.height - 2).fill()
        case .weatherAura(let colors, let border):
            let rect = fullRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if let grad = NSGradient(colors: colors) {
                grad.draw(in: rect, angle: 0)
            }
            NSGraphicsContext.restoreGraphicsState()
            border.setStroke()
            path.lineWidth = 0.85
            path.stroke()
        case .daylightTrack(let progress):
            let trackX: CGFloat = 2
            let trackW = max(24, size.width - 4)
            let trackRect = NSRect(x: trackX, y: 1.0, width: trackW, height: 2.0)
            let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1)
            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()
            if let grad = NSGradient(colors: [
                srgb(0x38BDF8),
                srgb(0xFBBF24),
                srgb(0xF97316),
                srgb(0x6366F1),
            ]) {
                grad.draw(in: trackRect, angle: 0)
            }
            NSGraphicsContext.restoreGraphicsState()

            let sunX = trackX + trackW * CGFloat(progress)
            let sunRect = NSRect(x: sunX - 2.4, y: 2.0 - 2.4, width: 4.8, height: 4.8)
            let sunDot = NSBezierPath(ovalIn: sunRect)
            NSColor.white.setFill()
            sunDot.fill()
            srgb(0xF59E0B).setStroke()
            sunDot.lineWidth = 1.0
            sunDot.stroke()
        case .splitRibbon(let leftCount, let leftColors, let rightFill, let border):
            let rect = fullRect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            var leftWidth: CGFloat = 0
            if leftCount > 0 {
                var w = paddingX
                for i in 0..<min(leftCount, atoms.count) {
                    if i > 0 { w += gap }
                    w += atoms[i].width
                }
                leftWidth = min(size.width, w + gap * 0.6)
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            rightFill.setFill()
            rect.fill()
            if leftWidth > 0 {
                let leftRect = NSRect(x: 0, y: 0, width: leftWidth, height: size.height)
                if let grad = NSGradient(colors: leftColors) {
                    grad.draw(in: leftRect, angle: -25)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            border.setStroke()
            path.lineWidth = 0.85
            path.stroke()
        }
    }

    // MARK: - 通用位图绘制与兜底

    private static func renderFallbackSymbol(isDark: Bool, scale: CGFloat) -> NSImage {
        renderImage(segments: [.symbol("calendar")], isDark: isDark, scale: scale)
    }

    private static func renderBitmap(
        logicalSize: NSSize,
        scale: CGFloat,
        isTemplate: Bool,
        draw: () -> Void
    ) -> NSImage {
        let pixelWidth = max(1, Int(ceil(logicalSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(logicalSize.height * scale)))

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
            draw()
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: logicalSize)
        image.addRepresentation(rep)
        image.isTemplate = isTemplate
        return image
    }

    // MARK: - 兼容旧版 [MenuBarSegment] 渲染接口

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
        let cacheKey = CalendarMenuBarImageCache.SegmentKey(
            isDark: isDark,
            scale: resolvedScale,
            logoID: resolvedLogo.map(ObjectIdentifier.init),
            segments: effective
        )
        if let cached = CalendarMenuBarImageCache.shared.segmentImage(for: cacheKey) {
            return cached
        }
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

        let image = renderBitmap(logicalSize: logicalSize, scale: resolvedScale, isTemplate: !hasColorLogo) {
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
        }
        CalendarMenuBarImageCache.shared.storeSegment(image, for: cacheKey)
        return image
    }

    private static func gap(after previous: MeasuredSegment, before next: MeasuredSegment) -> CGFloat {
        (previous.isSymbol && !next.isSymbol) ? 3 : 5
    }
}
