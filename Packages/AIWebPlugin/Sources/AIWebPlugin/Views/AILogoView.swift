import AppKit
import IronBowlKit
import SwiftUI

struct AILogoView: View {
    let logo: AILogoSource
    let logoStore: AILogoStore
    var size: CGFloat = 20
    var cornerRadius: CGFloat = 5
    var dimmed: Bool = false

    var body: some View {
        let resolved = logoStore.image(for: logo)
        Group {
            if let resolved {
                if resolved.isTemplate {
                    Image(nsImage: resolved.image)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(dimmed ? DS.textSecondary : DS.text)
                } else {
                    Image(nsImage: resolved.image)
                        .resizable()
                        .scaledToFit()
                        .opacity(dimmed ? 0.72 : 1)
                }
            } else {
                Image(systemName: logo.defaultSymbolFallback)
                    .font(DS.font(size * 0.65, .medium))
                    .foregroundStyle(dimmed ? DS.textSecondary : DS.text)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
    }
}
