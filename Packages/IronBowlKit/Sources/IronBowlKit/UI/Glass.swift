import SwiftUI

public extension Color {
    /// 饭碗琥珀色（与 App 的 AccentColor 一致，包内预览时兜底用）。
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.141)
}

/// 小号胶囊标签，比如"兜底""加班""已记录"。
public struct Tag: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(DS.font(11.5, .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }
}

/// 设置页里的说明文字。
public struct Hint: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
