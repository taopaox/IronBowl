import AppKit
import IronBowlKit
import SwiftUI

/// 首页「今天」主对话时间线：展示用户提问、实时功能卡片与带输出详情的助手回复。
struct HomeChatTimeline: View {
    let app: AppModel
    let messages: [ChatMessage]
    let detailLevel: ChatOutputDetailLevel
    let onAttachCardsToAsk: ([ChatCardAttachment]) -> Void
    let onRetry: (String) -> Void

    @State private var isNearBottom = true

    private var lastMessageSignature: String {
        guard let last = messages.last else { return "" }
        return "\(last.id)|\(last.content.count)|\(last.activities.count)|\(last.status.rawValue)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(messages) { message in
                            TimelineMessageView(
                                app: app,
                                message: message,
                                detailLevel: detailLevel,
                                onAttachCard: { card in
                                    onAttachCardsToAsk([card])
                                },
                                onAttachAllCards: { cards in
                                    onAttachCardsToAsk(cards)
                                },
                                onRetry: {
                                    onRetry(message.id)
                                }
                            )
                            .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("chat-bottom")
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let distance = geo.contentSize.height - (geo.contentOffset.y + geo.containerSize.height)
                    return distance <= 72
                } action: { _, near in
                    isNearBottom = near
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: lastMessageSignature) { _, _ in
                    if isNearBottom {
                        proxy.scrollTo("chat-bottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }

                if !isNearBottom {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down")
                            Text("回到底部")
                        }
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(DS.card, in: .capsule)
                        .overlay { Capsule().strokeBorder(DS.borderStrong) }
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 24)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct TimelineMessageView: View {
    let app: AppModel
    let message: ChatMessage
    let detailLevel: ChatOutputDetailLevel
    let onAttachCard: (ChatCardAttachment) -> Void
    let onAttachAllCards: ([ChatCardAttachment]) -> Void
    let onRetry: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserMessageBubble(app: app, message: message, onAttachCard: onAttachCard)
        case .card:
            StandaloneCardMessageView(
                app: app,
                message: message,
                onAttachCard: onAttachCard,
                onAttachAllCards: onAttachAllCards
            )
        case .assistant:
            AssistantMessageView(
                app: app,
                message: message,
                detailLevel: detailLevel,
                onAttachCard: onAttachCard,
                onRetry: onRetry
            )
        }
    }
}

private struct UserMessageBubble: View {
    let app: AppModel
    let message: ChatMessage
    let onAttachCard: (ChatCardAttachment) -> Void

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                if !message.cards.isEmpty {
                    HomeChatCardStrip(
                        app: app,
                        attachments: message.cards,
                        onAskWithCard: onAttachCard
                    )
                }
                Text(message.content)
                    .font(DS.body)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: 560, alignment: .leading)
            .background(DS.well, in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(DS.border) }

            HStack(spacing: 8) {
                if hovering {
                    Button {
                        copyTextToPasteboard(message.content)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(DS.font(11))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("复制消息")
                }
                Text(CN.time(message.createdAt))
                    .font(DS.font(11))
                    .monospacedDigit()
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
    }
}

private struct StandaloneCardMessageView: View {
    let app: AppModel
    let message: ChatMessage
    let onAttachCard: (ChatCardAttachment) -> Void
    let onAttachAllCards: ([ChatCardAttachment]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(DS.font(12))
                    .foregroundStyle(DS.brand)
                Text(message.content)
                    .font(DS.font(12.5, .medium))
                    .foregroundStyle(DS.textSecondary)
                Text("· \(CN.time(message.createdAt))")
                    .font(DS.font(11))
                    .monospacedDigit()
                    .foregroundStyle(DS.textTertiary)
                Spacer()
                if !message.cards.isEmpty {
                    Button {
                        onAttachAllCards(message.cards)
                    } label: {
                        Label("附加给 AI 提问", systemImage: "sparkles")
                            .font(DS.font(11.5, .medium))
                    }
                    .buttonStyle(.dsSecondary)
                    .controlSize(.small)
                }
            }

            HomeChatCardStrip(
                app: app,
                attachments: message.cards,
                onAskWithCard: onAttachCard
            )
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DS.border) }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantMessageView: View {
    let app: AppModel
    let message: ChatMessage
    let detailLevel: ChatOutputDetailLevel
    let onAttachCard: (ChatCardAttachment) -> Void
    let onRetry: () -> Void

    @State private var copied = false

    private var providerTitle: String {
        switch message.providerKind {
        case .agy: "Antigravity"
        case .codex: "Codex"
        case nil: message.modelName ?? "工作台规则"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: message.providerKind == nil ? "sparkles" : "cpu")
                    .font(DS.font(12))
                    .foregroundStyle(DS.brand)
                Text(providerTitle)
                    .font(DS.font(12.5, .semibold))
                    .foregroundStyle(DS.text)

                if message.providerKind != nil, let model = message.modelName, !model.isEmpty {
                    Text(model)
                        .font(DS.font(11))
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(DS.well, in: .capsule)
                }

                if message.status == .streaming {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("生成中")
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.brand)
                    }
                } else if message.status == .cancelled {
                    Text("已停止")
                        .font(DS.font(11))
                        .foregroundStyle(DS.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(DS.warning.opacity(0.12), in: .capsule)
                }

                Spacer(minLength: 8)

                if let duration = message.durationSeconds, message.status != .streaming {
                    Text(String(format: "%.1fs", duration))
                        .font(DS.font(11))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                }

                if let usageSummary = message.usage?.summaryText, message.status != .streaming {
                    Text(usageSummary)
                        .font(DS.font(11))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                }

                if !message.content.isEmpty {
                    Button {
                        copyTextToPasteboard(message.content)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(DS.font(11.5))
                    }
                    .buttonStyle(.dsGhost)
                    .help("复制回复内容")
                }
            }

            if message.hasDetails {
                HomeChatActivityView(message: message, detailLevel: detailLevel)
            }

            if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DSMarkdownView(text: message.content)
            } else if message.status == .streaming && !message.hasDetails {
                Text("正在思考并连接本地代理…")
                    .font(DS.body)
                    .foregroundStyle(DS.textTertiary)
            }

            if !message.cards.isEmpty {
                HomeChatCardStrip(
                    app: app,
                    attachments: message.cards,
                    onAskWithCard: onAttachCard
                )
            }

            if let errorMessage = message.errorMessage, !errorMessage.isEmpty {
                if message.status == .failed {
                    DSBanner(.danger, errorMessage, actionTitle: "重试", action: onRetry)
                } else if message.status == .cancelled {
                    DSBanner(.warning, errorMessage)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func copyTextToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
