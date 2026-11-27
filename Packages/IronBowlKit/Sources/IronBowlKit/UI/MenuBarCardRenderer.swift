import AppKit
import Foundation

/// 状态栏微缩仪表卡的颜色语义。
public nonisolated enum MenuBarCardTone: Sendable, Equatable {
    case amber
    case purple
    case green
    case rose
    case sky
    case indigo
    case slate
    case white

    func nsColor(isDark: Bool) -> NSColor {
        if isDark {
            switch self {
            case .amber:  NSColor(srgbRed: 251 / 255, green: 191 / 255, blue: 36 / 255, alpha: 1)   // #FBBF24
            case .purple: NSColor(srgbRed: 192 / 255, green: 132 / 255, blue: 252 / 255, alpha: 1)  // #C084FC
            case .green:  NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)   // #34D399
            case .rose:   NSColor(srgbRed: 251 / 255, green: 113 / 255, blue: 133 / 255, alpha: 1)  // #FB7185
            case .sky:    NSColor(srgbRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 1)   // #38BDF8
            case .indigo: NSColor(srgbRed: 165 / 255, green: 180 / 255, blue: 252 / 255, alpha: 1)  // #A5B4FC
            case .slate:  NSColor(srgbRed: 203 / 255, green: 213 / 255, blue: 225 / 255, alpha: 1)  // #CBD5E1
            case .white:  NSColor(srgbRed: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)  // #F8FAFC
            }
        } else {
            switch self {
            case .amber:  NSColor(srgbRed: 180 / 255, green: 83 / 255, blue: 9 / 255, alpha: 1)     // #B45309
            case .purple: NSColor(srgbRed: 126 / 255, green: 34 / 255, blue: 206 / 255, alpha: 1)   // #7E22CE
            case .green:  NSColor(srgbRed: 4 / 255, green: 120 / 255, blue: 87 / 255, alpha: 1)     // #047857
            case .rose:   NSColor(srgbRed: 190 / 255, green: 18 / 255, blue: 60 / 255, alpha: 1)    // #BE123C
            case .sky:    NSColor(srgbRed: 3 / 255, green: 105 / 255, blue: 161 / 255, alpha: 1)    // #0369A1
            case .indigo: NSColor(srgbRed: 67 / 255, green: 56 / 255, blue: 202 / 255, alpha: 1)    // #4338CA
            case .slate:  NSColor(srgbRed: 71 / 255, green: 85 / 255, blue: 105 / 255, alpha: 1)    // #475569
            case .white:  NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)     // #0F172A
            }
        }
    }
}

/// 状态栏微缩仪表卡的单个信息段。
public nonisolated enum MenuBarCardSegment: Sendable, Equatable {
    /// 上下双行堆叠仪表：上行小字标签/进度，下行大字等宽倒计时。
    case stacked(top: String, bottom: String, topTone: MenuBarCardTone)
    /// 单行语义色文本。
    case inline(text: String, tone: MenuBarCardTone)
}

private nonisolated final class MenuBarCardImageCache: @unchecked Sendable {
    struct Key: Equatable {
        let segments: [MenuBarCardSegment]
        let icon: String
        let iconImageID: ObjectIdentifier?
        let isDark: Bool
        let scale: CGFloat
    }

    static let shared = MenuBarCardImageCache()

    private let lock = NSLock()
    private let maxEntries = 6
    private var entries: [(key: Key, image: NSImage)] = []

    func image(for key: Key) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.key == key }?.image
    }

    func store(_ image: NSImage, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = entries.firstIndex(where: { $0.key == key }) {
            entries[idx] = (key, image)
            return
        }
        if entries.count >= maxEntries {
            entries.removeFirst()
        }
        entries.append((key, image))
    }
}

/// 主状态栏「双行微缩仪表卡」离线渲染器。
/// 绘制为 22pt 高的透明底全彩非模板 `NSImage`（`isTemplate = false`），无深色底框，并根据深浅色自适应高对比度文字色调。
public enum MenuBarCardRenderer {
    public static let barHeight: CGFloat = 22

    private enum MeasuredSegment {
        case stacked(top: NSAttributedString, bottom: NSAttributedString, width: CGFloat)
        case inline(attr: NSAttributedString, size: NSSize)

        var width: CGFloat {
            switch self {
            case .stacked(_, _, let width): width
            case .inline(_, let size): ceil(size.width)
            }
        }
    }

    public static func renderImage(
        segments: [MenuBarCardSegment],
        icon: String = "🍚",
        iconImage: NSImage? = nil,
        isDark: Bool = true,
        scale: CGFloat? = nil
    ) -> NSImage {
        let resolvedScale = max(1.0, scale ?? max(2.0, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0))
        let cacheKey = MenuBarCardImageCache.Key(
            segments: segments,
            icon: icon,
            iconImageID: iconImage.map(ObjectIdentifier.init),
            isDark: isDark,
            scale: resolvedScale
        )
        if let cached = MenuBarCardImageCache.shared.image(for: cacheKey) {
            return cached
        }
        let iconFont = NSFont.systemFont(ofSize: 12)
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .bold)
        let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

        let iconAttr = NSAttributedString(string: icon, attributes: [.font: iconFont])
        let iconSize: NSSize
        if let iconImage {
            let iconHeight: CGFloat = 19
            let raw = iconImage.size
            let iconWidth = (raw.height > 0 && raw.width > 0) ? ceil(iconHeight * (raw.width / raw.height)) : iconHeight
            iconSize = NSSize(width: iconWidth, height: iconHeight)
        } else {
            iconSize = iconAttr.size()
        }

        let measured: [MeasuredSegment] = segments.map { segment in
            switch segment {
            case .stacked(let top, let bottom, let topTone):
                let topAttr = NSAttributedString(
                    string: top,
                    attributes: [.font: topFont, .foregroundColor: topTone.nsColor(isDark: isDark)]
                )
                let bottomAttr = NSAttributedString(
                    string: bottom,
                    attributes: [.font: bottomFont, .foregroundColor: MenuBarCardTone.white.nsColor(isDark: isDark)]
                )
                let width = ceil(max(topAttr.size().width, bottomAttr.size().width))
                return .stacked(top: topAttr, bottom: bottomAttr, width: width)

            case .inline(let text, let tone):
                let attr = NSAttributedString(
                    string: text,
                    attributes: [.font: inlineFont, .foregroundColor: tone.nsColor(isDark: isDark)]
                )
                return .inline(attr: attr, size: attr.size())
            }
        }

        let horizontalPadding: CGFloat = 2
        let iconGap: CGFloat = 5
        let dividerGap: CGFloat = 5

        let totalWidth: CGFloat
        if measured.isEmpty {
            totalWidth = max(22, ceil(iconSize.width + 2))
        } else {
            let segmentsWidth = measured.reduce(CGFloat(0)) { $0 + $1.width }
            let dividersWidth = CGFloat(max(0, measured.count - 1)) * (dividerGap * 2 + 1)
            totalWidth = ceil(horizontalPadding * 2 + iconSize.width + iconGap + segmentsWidth + dividersWidth)
        }

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
            let fallback = NSImage(size: logicalSize)
            fallback.isTemplate = false
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

            let iconY = (barHeight - iconSize.height) / 2
            let drawIcon: (CGFloat) -> Void = { iconX in
                if let iconImage {
                    iconImage.draw(
                        in: NSRect(x: iconX, y: iconY, width: iconSize.width, height: iconSize.height),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                } else {
                    iconAttr.draw(at: NSPoint(x: iconX, y: iconY))
                }
            }
            if measured.isEmpty {
                let iconX = (totalWidth - iconSize.width) / 2
                drawIcon(iconX)
            } else {
                var x = horizontalPadding
                drawIcon(x)
                x += iconSize.width + iconGap

                for (index, item) in measured.enumerated() {
                    if index > 0 {
                        x += dividerGap
                        NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.22 : 0.18).setFill()
                        NSRect(x: x, y: (barHeight - 11) / 2, width: 1, height: 11).fill()
                        x += 1 + dividerGap
                    }

                    switch item {
                    case .stacked(let topAttr, let bottomAttr, let width):
                        bottomAttr.draw(at: NSPoint(x: x, y: 1.4))
                        topAttr.draw(at: NSPoint(x: x, y: 11.2))
                        x += width
                    case .inline(let attr, let size):
                        let y = (barHeight - size.height) / 2
                        attr.draw(at: NSPoint(x: x, y: y))
                        x += ceil(size.width)
                    }
                }
            }

            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }

        let image = NSImage(size: logicalSize)
        image.addRepresentation(rep)
        image.isTemplate = false
        MenuBarCardImageCache.shared.store(image, for: cacheKey)
        return image
    }
}
