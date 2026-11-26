import AppKit
import IronBowlKit
import Testing

@MainActor @Test func menuBarCardRendererProducesNonTemplateColoredDashboardImage() throws {
    let emptyImg = MenuBarCardRenderer.renderImage(segments: [], scale: 2)
    #expect(!emptyImg.isTemplate)
    #expect(emptyImg.size.height == MenuBarCardRenderer.barHeight)
    #expect(emptyImg.size.width >= 24)

    let singleImg = MenuBarCardRenderer.renderImage(
        segments: [.stacked(top: "距下班 · 64%", bottom: "3小时16分", topTone: .amber)],
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
        scale: 2
    )
    #expect(!overtimeImg.isTemplate)
    #expect(overtimeImg.size.height == MenuBarCardRenderer.barHeight)
    #expect(overtimeImg.size.width > singleImg.size.width)

    let rep = try #require(overtimeImg.representations.first as? NSBitmapImageRep)
    #expect(rep.pixelsWide == Int(ceil(overtimeImg.size.width * 2)))
    #expect(rep.pixelsHigh == Int(ceil(MenuBarCardRenderer.barHeight * 2)))

    // 验证画布内包含深石板底色像素与非空白高亮前景像素（确认图像正常绘制非空）
    var hasDarkBackground = false
    var hasBrightForeground = false
    for y in stride(from: 6, to: rep.pixelsHigh - 6, by: 2) {
        for x in stride(from: 6, to: rep.pixelsWide - 6, by: 2) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else { continue }
            let luminance = color.redComponent * 0.299 + color.greenComponent * 0.587 + color.blueComponent * 0.114
            if luminance < 0.2 { hasDarkBackground = true }
            if luminance > 0.6 { hasBrightForeground = true }
        }
    }
    #expect(hasDarkBackground)
    #expect(hasBrightForeground)
}

@MainActor @Test func menuBarCardRendererSupportsCustomIconImage() throws {
    let customIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        return true
    }

    let emptyWithImage = MenuBarCardRenderer.renderImage(segments: [], iconImage: customIcon, scale: 2)
    #expect(!emptyWithImage.isTemplate)
    #expect(emptyWithImage.size.height == MenuBarCardRenderer.barHeight)
    #expect(emptyWithImage.size.width >= 24)

    let withSegments = MenuBarCardRenderer.renderImage(
        segments: [.stacked(top: "距下班 · 50%", bottom: "2小时00分", topTone: .amber)],
        iconImage: customIcon,
        scale: 2
    )
    #expect(!withSegments.isTemplate)
    #expect(withSegments.size.height == MenuBarCardRenderer.barHeight)
    #expect(withSegments.size.width > emptyWithImage.size.width)

    let rep = try #require(emptyWithImage.representations.first as? NSBitmapImageRep)
    var hasOrangeIconPixel = false
    for y in 6..<(rep.pixelsHigh - 6) {
        for x in 6..<(rep.pixelsWide - 6) {
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
