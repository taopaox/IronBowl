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
