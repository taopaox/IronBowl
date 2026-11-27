import AppKit
import IronBowlKit
import Testing

@MainActor @Test func menuBarCardRendererProducesNonTemplateColoredDashboardImage() throws {
    let emptyImg = MenuBarCardRenderer.renderImage(segments: [], isDark: true, scale: 2)
    #expect(!emptyImg.isTemplate)
    #expect(emptyImg.size.height == MenuBarCardRenderer.barHeight)
    #expect(emptyImg.size.width >= 22)

    let singleImg = MenuBarCardRenderer.renderImage(
        segments: [.stacked(top: "距下班 · 64%", bottom: "3小时16分", topTone: .amber)],
        isDark: true,
        scale: 2
    )
    #expect(!singleImg.isTemplate)
    #expect(singleImg.size.height == MenuBarCardRenderer.barHeight)
    #expect(singleImg.size.width > emptyImg.size.width)

    let overtimeImg = MenuBarCardRenderer.renderImage(
        segments: [
            .stacked(top: "加班 · 51%", bottom: "5小时16分", topTone: .purple),
            .inline(text: "●", tone: .rose),
            .inline(text: "晴 12°", tone: .sky),
        ],
        isDark: true,
        scale: 2
    )
    #expect(!overtimeImg.isTemplate)
    #expect(overtimeImg.size.height == MenuBarCardRenderer.barHeight)
    #expect(overtimeImg.size.width > singleImg.size.width)

    let rep = try #require(overtimeImg.representations.first as? NSBitmapImageRep)
    #expect(rep.pixelsWide == Int(ceil(overtimeImg.size.width * 2)))
    #expect(rep.pixelsHigh == Int(ceil(MenuBarCardRenderer.barHeight * 2)))
    #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0)

    // 深色模式下背景透明、前景为高亮度像素
    var hasBrightForeground = false
    for y in stride(from: 4, to: rep.pixelsHigh - 4, by: 2) {
        for x in stride(from: 4, to: rep.pixelsWide - 4, by: 2) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
            let luminance = color.redComponent * 0.299 + color.greenComponent * 0.587 + color.blueComponent * 0.114
            if luminance > 0.6 { hasBrightForeground = true }
        }
    }
    #expect(hasBrightForeground)

    // 浅色模式下背景同样透明，且前景为高对比度深色像素
    let lightImg = MenuBarCardRenderer.renderImage(
        segments: [
            .stacked(top: "加班 · 51%", bottom: "5小时16分", topTone: .purple),
            .inline(text: "●", tone: .rose),
            .inline(text: "晴 12°", tone: .sky),
        ],
        isDark: false,
        scale: 2
    )
    let lightRep = try #require(lightImg.representations.first as? NSBitmapImageRep)
    #expect((lightRep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0)
    var hasDarkForeground = false
    for y in stride(from: 4, to: lightRep.pixelsHigh - 4, by: 2) {
        for x in stride(from: 4, to: lightRep.pixelsWide - 4, by: 2) {
            guard let color = lightRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
            let luminance = color.redComponent * 0.299 + color.greenComponent * 0.587 + color.blueComponent * 0.114
            if luminance < 0.35 { hasDarkForeground = true }
        }
    }
    #expect(hasDarkForeground)
}

@MainActor @Test func menuBarCardRendererSupportsCustomIconImage() throws {
    let squareIcon = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }
    let wideIcon = NSImage(size: NSSize(width: 60, height: 40), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }

    let emptyWithSquare = MenuBarCardRenderer.renderImage(segments: [], iconImage: squareIcon, scale: 2)
    let emptyWithWide = MenuBarCardRenderer.renderImage(segments: [], iconImage: wideIcon, scale: 2)
    #expect(!emptyWithWide.isTemplate)
    #expect(emptyWithWide.size.height == MenuBarCardRenderer.barHeight)
    #expect(emptyWithWide.size.width > emptyWithSquare.size.width)

    let withSegments = MenuBarCardRenderer.renderImage(
        segments: [.stacked(top: "距下班 · 50%", bottom: "2小时00分", topTone: .amber)],
        iconImage: wideIcon,
        isDark: false,
        scale: 2
    )
    #expect(!withSegments.isTemplate)
    #expect(withSegments.size.height == MenuBarCardRenderer.barHeight)
    #expect(withSegments.size.width > emptyWithWide.size.width)

    let rep = try #require(emptyWithWide.representations.first as? NSBitmapImageRep)
    #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0)
    var hasOrangeIconPixel = false
    for y in 4..<(rep.pixelsHigh - 4) {
        for x in 4..<(rep.pixelsWide - 4) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
            if color.redComponent > 0.7, color.greenComponent > 0.3, color.blueComponent < 0.3 {
                hasOrangeIconPixel = true
                break
            }
        }
        if hasOrangeIconPixel { break }
    }
    #expect(hasOrangeIconPixel)
}

@MainActor @Test func menuBarCardRendererSupportsIconlessDashboardMode() throws {
    let icon = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }
    let segments: [MenuBarCardSegment] = [
        .stacked(top: "距下班 · 64%", bottom: "3小时16分", topTone: .amber),
        .inline(text: "●", tone: .rose),
    ]
    let withIcon = MenuBarCardRenderer.renderImage(segments: segments, iconImage: icon, showIcon: true, isDark: true, scale: 2)
    let withoutIcon = MenuBarCardRenderer.renderImage(segments: segments, iconImage: icon, showIcon: false, isDark: true, scale: 2)

    #expect(!withoutIcon.isTemplate)
    #expect(withoutIcon.size.height == MenuBarCardRenderer.barHeight)
    #expect(withoutIcon.size.width < withIcon.size.width)

    let emptyWithoutIcon = MenuBarCardRenderer.renderImage(segments: [], iconImage: icon, showIcon: false, isDark: true, scale: 2)
    #expect(emptyWithoutIcon.size.height == MenuBarCardRenderer.barHeight)
    #expect(emptyWithoutIcon.size.width == 1)
}

@MainActor @Test func menuBarCardRendererDrawsLogoWithUnreadBadge() throws {
    let icon = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }

    let zeroBadge = MenuBarCardRenderer.renderLogoBadgeImage(iconImage: icon, unreadCount: 0, isDark: true, scale: 2)
    let smallBadge = MenuBarCardRenderer.renderLogoBadgeImage(iconImage: icon, unreadCount: 5, isDark: true, scale: 2)
    let overflowBadge = MenuBarCardRenderer.renderLogoBadgeImage(iconImage: icon, unreadCount: 120, isDark: false, scale: 2)

    #expect(!zeroBadge.isTemplate)
    #expect(!smallBadge.isTemplate)
    #expect(!overflowBadge.isTemplate)
    #expect(zeroBadge.size.height == MenuBarCardRenderer.barHeight)
    #expect(smallBadge.size.height == MenuBarCardRenderer.barHeight)
    #expect(overflowBadge.size.height == MenuBarCardRenderer.barHeight)
    #expect(smallBadge.size.width >= zeroBadge.size.width)
    #expect(overflowBadge.size.width > smallBadge.size.width)

    let zeroRep = try #require(zeroBadge.representations.first as? NSBitmapImageRep)
    let smallRep = try #require(smallBadge.representations.first as? NSBitmapImageRep)

    func containsRedBadgePixel(in rep: NSBitmapImageRep) -> Bool {
        for y in 0..<rep.pixelsHigh {
            for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.7 else { continue }
                if color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    return true
                }
            }
        }
        return false
    }

    #expect(!containsRedBadgePixel(in: zeroRep))
    #expect(containsRedBadgePixel(in: smallRep))
}
