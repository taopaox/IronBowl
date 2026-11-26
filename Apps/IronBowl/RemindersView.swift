import AppKit
import IronBowlKit
import SwiftUI

/// 左侧「消息提醒」页面：展示所有历史提醒消息，支持按状态/来源筛选、搜索、已读管理与快捷跳转。
struct RemindersView: View {
    @Bindable var app: AppModel

    enum ReadFilter: Hashable {
        case all
        case unread
        case read
    }

    private struct DaySection: Identifiable {
        let day: Date
        let title: String
        let records: [ReminderHistoryRecord]
        var id: Date { day }
    }

    @State private var tab: ReadFilter = .all
    @State private var sourceFilter: ReminderSource? = nil
    @State private var query = ""
    @State private var confirmClear = false
    @State private var copiedRecordID: Int64?
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    private var allRecords: [ReminderHistoryRecord] {
        app.reminders.history
    }

    private var unreadRecords: [ReminderHistoryRecord] {
        allRecords.filter { !$0.isRead }
    }

    private var readRecords: [ReminderHistoryRecord] {
        allRecords.filter(\.isRead)
    }

    private var filteredRecords: [ReminderHistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allRecords.filter { record in
            switch tab {
            case .all: break
            case .unread: if record.isRead { return false }
            case .read: if !record.isRead { return false }
            }
            if let sourceFilter, record.source != sourceFilter {
                return false
            }
            if !trimmed.isEmpty {
                let hitTitle = record.title.localizedCaseInsensitiveContains(trimmed)
                let hitMessage = record.message.localizedCaseInsensitiveContains(trimmed)
                if !hitTitle && !hitMessage { return false }
            }
            return true
        }
    }

    private var hasActiveFilter: Bool {
        tab != .all || sourceFilter != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecords) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let records = (grouped[day] ?? []).sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }
            return DaySection(day: day, title: sectionTitle(for: day), records: records)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("消息提醒", topPadding: 8) {
                DSTabs(selection: $tab, options: [
                    (.all, "全部 (\(allRecords.count))"),
                    (.unread, "未读 (\(unreadRecords.count))"),
                    (.read, "已读 (\(readRecords.count))"),
                ])
                .padding(.leading, sidebarCollapsed ? 38 : 0)
            } actions: {
                if !unreadRecords.isEmpty {
                    Button(sourceFilter == nil ? "全部标为已读" : "当前来源标为已读") {
                        app.reminders.markAllRead(source: sourceFilter)
                    }
                    .buttonStyle(.dsSecondary)
                }
                if !allRecords.isEmpty {
                    Button("清空历史") {
                        confirmClear = true
                    }
                    .buttonStyle(.dsSecondary)
                }
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metricsBar
                    filterToolbar
                    recordsContent
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.canvas)
        .alert(sourceFilter == nil ? "清空全部历史消息？" : "清空「\(sourceFilter?.displayName ?? "")」历史消息？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                app.reminders.clearHistory(source: sourceFilter)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(sourceFilter == nil ? "将移除所有已保存的历史提醒记录，此操作不可撤销。" : "将移除该来源下的全部历史提醒记录，其他来源保持不变。")
        }
    }

    // MARK: - 统计指标

    private var metricsBar: some View {
        let unreadCount = unreadRecords.count
        let todayCount = allRecords.filter { Calendar.current.isDateInToday($0.createdAt) }.count
        let latest = allRecords.first

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            DSMetric(
                "未读消息",
                value: "\(unreadCount)",
                detail: unreadDetailText(unreadCount: unreadCount),
                valueColor: unreadCount > 0 ? DS.danger : DS.text
            )
            DSMetric(
                "今日提醒",
                value: "\(todayCount) 条",
                detail: "累计保存 \(allRecords.count) 条"
            )
            DSMetric(
                "最近一条",
                value: latest.map { formatLatestTime($0.createdAt) } ?? "暂无",
                detail: latest?.title ?? "触发的提醒都会自动沉淀在这里"
            )
        }
    }

    private func unreadDetailText(unreadCount: Int) -> String {
        guard unreadCount > 0 else { return "所有消息均已查看" }
        let grouped = Dictionary(grouping: unreadRecords, by: \.source)
        let parts = ReminderSource.allCases.compactMap { src -> String? in
            guard let count = grouped[src]?.count, count > 0 else { return nil }
            return "\(src.displayName) \(count)"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 筛选栏

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(13))
                    .foregroundStyle(DS.textTertiary)
                TextField("搜索标题或提醒正文", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: DS.s(30))
            .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }

            let sourceOptions: [DSPickerOption<ReminderSource?>] =
                [DSPickerOption(nil, title: "全部来源")]
                + ReminderSource.allCases.map { DSPickerOption(Optional($0), title: $0.displayName) }
            DSPicker(selection: $sourceFilter, options: sourceOptions, width: 150)
        }
    }

    // MARK: - 列表内容

    @ViewBuilder
    private var recordsContent: some View {
        if allRecords.isEmpty {
            DSCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("暂无历史消息提醒", systemImage: "bell.slash")
                        .font(DS.rowTitle)
                        .foregroundStyle(DS.text)
                    Text("禅道写日志提醒、定时任务通知、考勤异常提示等都会自动记录在这里，方便随时回看。")
                        .font(DS.body)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
            }
        } else if daySections.isEmpty {
            DSCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("没有符合当前筛选条件的提醒")
                            .font(DS.rowTitle)
                        Text("可以切换上方标签、调整来源筛选或清空搜索关键词。")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                    Spacer()
                    if hasActiveFilter {
                        Button("重置筛选") {
                            tab = .all
                            sourceFilter = nil
                            query = ""
                        }
                        .buttonStyle(.dsSecondary)
                    }
                }
                .padding(.vertical, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(daySections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(section.title)
                                .font(DS.sectionTitle)
                                .foregroundStyle(DS.textSecondary)
                            Text("(\(section.records.count))")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                                .monospacedDigit()
                        }
                        .padding(.leading, 2)

                        VStack(spacing: 10) {
                            ForEach(section.records) { record in
                                ReminderHistoryCard(
                                    record: record,
                                    targetActionTitle: targetTitle(for: record),
                                    isCopied: copiedRecordID == record.id,
                                    onMarkReadIfNeeded: {
                                        if !record.isRead {
                                            app.reminders.setRead(id: record.id, isRead: true)
                                        }
                                    },
                                    onToggleRead: {
                                        app.reminders.setRead(id: record.id, isRead: !record.isRead)
                                    },
                                    onOpenTarget: {
                                        openTarget(for: record)
                                    },
                                    onCopy: {
                                        copyRecord(record)
                                    },
                                    onDelete: {
                                        app.reminders.deleteHistory(id: record.id)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 跳转与辅助

    private func targetTitle(for record: ReminderHistoryRecord) -> String? {
        if record.targetSettingsPage != nil {
            return "前往设置"
        }
        if let pluginID = record.targetPluginID,
           app.enabledIDs.contains(pluginID),
           let plugin = app.plugin(pluginID) {
            return "前往\(plugin.sidebarTitle)"
        }
        return nil
    }

    private func openTarget(for record: ReminderHistoryRecord) {
        if !record.isRead {
            app.reminders.setRead(id: record.id, isRead: true)
        }
        if let settingsPage = record.targetSettingsPage {
            app.openSettings(page: settingsPage)
            return
        }
        if let pluginID = record.targetPluginID,
           app.enabledIDs.contains(pluginID),
           let plugin = app.plugin(pluginID) {
            plugin.onSidebarSelect()
            app.open(plugin: pluginID)
        }
    }

    private func copyRecord(_ record: ReminderHistoryRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(record.title)\n\(record.message)", forType: .string)
        copiedRecordID = record.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedRecordID == record.id {
                copiedRecordID = nil
            }
        }
    }

    private func sectionTitle(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        return sameYear ? "\(CN.monthDay(day)) \(CN.weekdayShort(day))" : CN.full(day)
    }

    private func formatLatestTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天 \(CN.time(date))" }
        if cal.isDateInYesterday(date) { return "昨天 \(CN.time(date))" }
        return CN.dateTime(date)
    }
}

private struct ReminderHistoryCard: View {
    let record: ReminderHistoryRecord
    let targetActionTitle: String?
    let isCopied: Bool
    let onMarkReadIfNeeded: () -> Void
    let onToggleRead: () -> Void
    let onOpenTarget: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: record.systemImage)
                            .font(DS.font(15))
                            .foregroundStyle(sourceTint)
                            .frame(width: DS.s(32), height: DS.s(32))
                            .background(sourceTint.opacity(0.12), in: .rect(cornerRadius: 8))

                        if !record.isRead {
                            Circle()
                                .fill(DS.danger)
                                .frame(width: 8, height: 8)
                                .overlay {
                                    Circle().strokeBorder(DS.card, lineWidth: 1.5)
                                }
                                .offset(x: 2, y: -2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(record.title)
                                .font(DS.font(14.5, record.isRead ? .medium : .semibold))
                                .foregroundStyle(DS.text)
                                .lineLimit(2)

                            Spacer(minLength: 6)

                            Text(CN.time(record.createdAt))
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                                .monospacedDigit()
                                .help(CN.dateTime(record.createdAt))
                        }

                        HStack(spacing: 6) {
                            Tag(record.source.displayName, color: sourceTint)
                            Tag(record.style.shortDisplayName, color: DS.textSecondary)

                            if !record.deliveryStatus.isSuccess {
                                Tag(
                                    record.deliveryStatus.displayName,
                                    color: record.deliveryStatus == .failed ? DS.danger : DS.warning
                                )
                                .help(record.deliveryDetail)
                            }

                            if let handledTitle = record.handledActionTitle {
                                Tag("已操作：\(handledTitle)", color: DS.success)
                            }
                        }
                    }
                }
                .contentShape(.rect)
                .onTapGesture {
                    onMarkReadIfNeeded()
                }

                Text(record.message)
                    .font(DS.body)
                    .foregroundStyle(record.isRead ? DS.textSecondary : DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, DS.s(42))

                if !record.deliveryStatus.isSuccess, !record.deliveryDetail.isEmpty {
                    Text(record.deliveryDetail)
                        .font(DS.caption)
                        .foregroundStyle(record.deliveryStatus == .failed ? DS.danger : DS.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, DS.s(42))
                }

                HStack(spacing: 6) {
                    Spacer(minLength: 0)

                    if let targetActionTitle {
                        Button(targetActionTitle, action: onOpenTarget)
                            .buttonStyle(.dsSecondary)
                    }

                    Button(record.isRead ? "标为未读" : "标为已读", action: onToggleRead)
                        .buttonStyle(.dsGhost)

                    Button(isCopied ? "已复制" : "复制", action: onCopy)
                        .buttonStyle(.dsGhost)

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.dsGhost)
                    .help("删除此条消息")
                }
            }
        }
    }

    private var sourceTint: Color {
        switch record.source {
        case .zentao: DS.brand
        case .scheduler: .indigo
        case .attendance: DS.warning
        case .general: DS.toggle
        }
    }
}
