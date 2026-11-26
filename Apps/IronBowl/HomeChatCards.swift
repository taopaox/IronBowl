import IronBowlKit
import SwiftUI

/// 汇总首页「今天」可用的核心卡片与已启用插件卡片，并提供对话内活卡片渲染与选择器。
enum HomeCardCatalog {
    static func coreCards(for app: AppModel) -> [HomeCard] {
        let cal = app.workCalendar
        let now = app.now
        return [
            HomeCard(
                id: "core.lunar",
                label: CN.monthDay(now) + " " + CN.weekday(now),
                value: { WorkCalendar.lunarString(app.now) },
                detail: {
                    let today = app.now
                    guard let h = cal.nextHoliday(after: today) else { return nil }
                    let days = Calendar.current.dateComponents(
                        [.day],
                        from: Calendar.current.startOfDay(for: today),
                        to: h.date
                    ).day ?? 0
                    return "距\(h.name) \(days) 天"
                }
            ),
            HomeCard(
                id: "core.offwork",
                label: "下班",
                value: {
                    let _ = app.now
                    let today = Date()
                    if cal.isWorkday(today) {
                        guard let end = cal.effectiveWorkEnd(on: today), end > today else { return "已下班" }
                        return countdown(to: end, from: today) + " 后"
                    }
                    let ot = cal.overtimeHours(on: today)
                    return ot > 0 ? "加班 \(WorkCalendar.hoursText(ot))h" : "已下班"
                },
                detail: {
                    let _ = app.now
                    let today = Date()
                    let text: String
                    if cal.isWorkday(today) {
                        text = cal.scheduleText(on: today)
                    } else if cal.overtimeHours(on: today) > 0 {
                        text = "休息日加班"
                    } else {
                        text = cal.scheduleText(on: today)
                    }
                    guard app.settings[WorkCalendar.dingtalkEnabledKey],
                          cal.clockIn(on: today) == nil,
                          cal.attendanceIssue?.needsUserAction == true else { return text }
                    return text + " · 钉钉同步不可用"
                }
            ),
        ]
    }

    static func allCards(for app: AppModel) -> [HomeCard] {
        coreCards(for: app) + app.enabledPlugins.flatMap(\.homeCards)
    }

    static func snapshot(of card: HomeCard) -> ChatCardAttachment {
        ChatCardAttachment(
            cardID: card.id,
            label: card.label,
            valueSnapshot: card.value(),
            detailSnapshot: card.detail()
        )
    }

    static func liveCard(id: String, in app: AppModel) -> HomeCard? {
        allCards(for: app).first { $0.id == id }
    }
}

/// 对话流中的功能卡片网格：优先实时联动已启用插件，停用或动作结果卡片展示快照。
struct HomeChatCardStrip: View {
    let app: AppModel
    let attachments: [ChatCardAttachment]
    var onAskWithCard: ((ChatCardAttachment) -> Void)?

    private var interactiveAttachments: [ChatCardAttachment] {
        attachments.filter { resolveInteractiveView(for: $0) != nil }
    }

    private var metricAttachments: [ChatCardAttachment] {
        attachments.filter { resolveInteractiveView(for: $0) == nil }
    }

    private var columns: [GridItem] {
        if metricAttachments.count <= 1 {
            return [GridItem(.flexible())]
        }
        return [GridItem(.adaptive(minimum: 180), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(interactiveAttachments) { attachment in
                if let view = resolveInteractiveView(for: attachment) {
                    view
                }
            }

            if !metricAttachments.isEmpty {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(metricAttachments) { attachment in
                        HomeChatCardCell(
                            app: app,
                            attachment: attachment,
                            onAskWithCard: onAskWithCard
                        )
                    }
                }
            }
        }
    }

    private func resolveInteractiveView(for attachment: ChatCardAttachment) -> AnyView? {
        for plugin in app.enabledPlugins {
            if let view = plugin.makeInteractiveChatCard(for: attachment) {
                return view
            }
        }
        return nil
    }
}

private struct HomeChatCardCell: View {
    let app: AppModel
    let attachment: ChatCardAttachment
    var onAskWithCard: ((ChatCardAttachment) -> Void)?
    @State private var hovering = false

    private var liveCard: HomeCard? {
        HomeCardCatalog.liveCard(id: attachment.cardID, in: app)
    }

    private var resolvedLabel: String {
        liveCard?.label ?? attachment.label
    }

    private var resolvedValue: String {
        liveCard?.value() ?? attachment.valueSnapshot
    }

    private var resolvedDetail: String? {
        liveCard?.detail() ?? attachment.detailSnapshot
    }

    private var valueColor: Color {
        if attachment.isError { return DS.danger }
        if attachment.cardID == "zentao.quickLog" { return DS.success }
        return DS.text
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                liveCard?.action?()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(resolvedLabel)
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                        if liveCard != nil {
                            Text("实时")
                                .font(DS.font(10, .medium))
                                .foregroundStyle(DS.toggle)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(DS.toggle.opacity(0.12), in: .capsule)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(resolvedValue)
                        .font(DS.font(19, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let detail = resolvedDetail, !detail.isEmpty {
                        Text(detail)
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    attachment.isError ? DS.danger.opacity(0.08) : DS.well,
                    in: .rect(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(hovering && liveCard?.action != nil ? DS.borderStrong : DS.border)
                }
            }
            .buttonStyle(.plain)
            .disabled(liveCard?.action == nil)

            if hovering, let onAskWithCard {
                Button {
                    let current = ChatCardAttachment(
                        cardID: attachment.cardID,
                        label: resolvedLabel,
                        valueSnapshot: resolvedValue,
                        detailSnapshot: resolvedDetail,
                        isError: attachment.isError
                    )
                    onAskWithCard(current)
                } label: {
                    Label("问 AI", systemImage: "sparkles")
                        .font(DS.font(11, .medium))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DS.card, in: .capsule)
                        .overlay { Capsule().strokeBorder(DS.borderStrong) }
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("把这张卡片附加到提问输入框")
            }
        }
        .onHover { hovering = $0 }
    }
}

/// 插入功能卡片的弹出面板：支持直接插入对话流，或附加到当前提问。
struct HomeCardPickerPopover: View {
    let app: AppModel
    let onInsertCards: ([ChatCardAttachment]) -> Void
    let onAttachCard: (ChatCardAttachment) -> Void
    let onSwitchToLogMode: (() -> Void)?

    var body: some View {
        let cards = HomeCardCatalog.allCards(for: app)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("插入工作台功能卡片")
                        .font(DS.font(14, .semibold))
                    Text("卡片会在对话中保持实时状态，也可附加给 AI 解读。")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(DS.border)

            VStack(spacing: 6) {
                if app.enabledPlugins.contains(where: { $0.id == "zentao.log" }) {
                    Button {
                        let today = WorkCalendar.dayString(Date())
                        onInsertCards([
                            ChatCardAttachment(
                                cardID: "zentao.daily.interactive:\(today)",
                                label: "今日日报",
                                valueSnapshot: "可编辑操作",
                                detailSnapshot: today
                            ),
                        ])
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(DS.brand)
                            Text("插入「今日日报」可操作卡片（编辑 / 提交禅道）")
                                .font(DS.font(13, .medium))
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(DS.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(DS.well, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    onInsertCards(cards.map(HomeCardCatalog.snapshot(of:)))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(DS.brand)
                        Text("插入全部今日概览（\(cards.count) 张卡片）")
                            .font(DS.font(13, .medium))
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(DS.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(DS.well, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                if let onSwitchToLogMode {
                    Button {
                        onSwitchToLogMode()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(DS.toggle)
                            Text("切到「记日志」模式（一句话写入禅道草稿）")
                                .font(DS.font(13, .medium))
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(DS.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(DS.well, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().overlay(DS.border)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(cards) { card in
                        let snapshot = HomeCardCatalog.snapshot(of: card)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.label)
                                    .font(DS.font(13, .medium))
                                Text(snapshot.valueSnapshot)
                                    .font(DS.font(12))
                                    .foregroundStyle(DS.textSecondary)
                                    .lineLimit(1)
                                if let detail = snapshot.detailSnapshot, !detail.isEmpty {
                                    Text(detail)
                                        .font(DS.font(11))
                                        .foregroundStyle(DS.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 6)
                            Button("附加") {
                                onAttachCard(snapshot)
                            }
                            .buttonStyle(.dsSecondary)
                            .controlSize(.small)
                            .help("附加到下方提问输入框")

                            Button("插入") {
                                onInsertCards([snapshot])
                            }
                            .buttonStyle(.dsPrimary)
                            .controlSize(.small)
                            .help("直接插入到当前对话流")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(DS.card, in: .rect(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border) }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: DS.s(300))
        }
        .frame(width: DS.s(380))
        .background(DS.canvas)
    }
}
