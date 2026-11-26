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

    var nsColor: NSColor {
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
    }
}

/// 状态栏微缩仪表卡的单个信息段。
public nonisolated enum MenuBarCardSegment: Sendable, Equatable {
    /// 上下双行堆叠仪表：上行小字标签/进度，下行大字等宽倒计时。
    case stacked(top: String, bottom: String, topTone: MenuBarCardTone)
    /// 单行语义色文本。
    case inline(text: String, tone: MenuBarCardTone)
}

/// 主状态栏「双行微缩仪表卡」离线渲染器。
/// 绘制为 22pt 高的全彩非模板 `NSImage`（`isTemplate = false`），在浅色与深色菜单栏上均保持高对比度。
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
        scale: CGFloat? = nil
    ) -> NSImage {
        let resolvedScale = max(1.0, scale ?? max(2.0, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0))
        let iconFont = NSFont.systemFont(ofSize: 12)
        let topFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .semibold)
        let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .bold)
        let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)

        let iconAttr = NSAttributedString(string: icon, attributes: [.font: iconFont])
        let iconSize = iconAttr.size()

        let measured: [MeasuredSegment] = segments.map { segment in
            switch segment {
            case .stacked(let top, let bottom, let topTone):
                let topAttr = NSAttributedString(
                    string: top,
                    attributes: [.font: topFont, .foregroundColor: topTone.nsColor]
                )
                let bottomAttr = NSAttributedString(
                    string: bottom,
                    attributes: [.font: bottomFont, .foregroundColor: MenuBarCardTone.white.nsColor]
                )
                let width = ceil(max(topAttr.size().width, bottomAttr.size().width))
                return .stacked(top: topAttr, bottom: bottomAttr, width: width)

            case .inline(let text, let tone):
                let attr = NSAttributedString(
                    string: text,
                    attributes: [.font: inlineFont, .foregroundColor: tone.nsColor]
                )
                return .inline(attr: attr, size: attr.size())
            }
        }

        let horizontalPadding: CGFloat = 7
        let iconGap: CGFloat = 5
        let dividerGap: CGFloat = 5

        let totalWidth: CGFloat
        if measured.isEmpty {
            totalWidth = max(24, ceil(iconSize.width + 10))
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

            // 深石板底色卡片 + 1px 柔和白边
            let cardRect = NSRect(x: 0.5, y: 0.5, width: totalWidth - 1, height: barHeight - 1)
            let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 5.5, yRadius: 5.5)
            NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 0.94).setFill()
            cardPath.fill()

            NSColor(white: 1, alpha: 0.18).setStroke()
            cardPath.lineWidth = 1
            cardPath.stroke()

            let iconY = (barHeight - iconSize.height) / 2
            if measured.isEmpty {
                let iconX = (totalWidth - iconSize.width) / 2
                iconAttr.draw(at: NSPoint(x: iconX, y: iconY))
            } else {
                var x = horizontalPadding
                iconAttr.draw(at: NSPoint(x: x, y: iconY))
                x += iconSize.width + iconGap

                for (index, item) in measured.enumerated() {
                    if index > 0 {
                        x += dividerGap
                        NSColor(white: 1, alpha: 0.16).setFill()
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
        return image
    }
}
