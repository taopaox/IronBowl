import AppKit
import Foundation

/// 饭碗应用全局品牌信息与官方标语。
public nonisolated enum AppBrand {
    public static let name = "饭碗"
    public static let englishName = "IronBowl"
    public static let slogan = "先把饭碗端稳，再慢慢加菜，不烧心。"

    /// 供 macOS 原生「关于」面板展示的居中品牌说明文案。
    public static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4

        let result = NSMutableAttributedString(
            string: slogan,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        return result
    }
}
