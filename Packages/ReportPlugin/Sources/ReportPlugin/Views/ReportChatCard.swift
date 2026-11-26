import AppKit
import IronBowlKit
import SwiftUI

/// 在首页对话流内展示并操作的周报 / 月报交互卡片。
struct ReportChatCard: View {
    @Bindable var model: WeeklyReportModel
    let periodKind: ReportPeriodKind
    let periodKey: String

    @State private var expanded = false
    @State private var copied = false
    @State private var operating = false

    private var isCurrentActivePeriod: Bool {
        model.activePeriodKey == periodKey
    }

    private var savedTitle: String {
        if isCurrentActivePeriod, !model.reportTitle.isEmpty {
            return model.reportTitle
        }
        switch periodKind {
        case .weekly:
            return model.store.report(forWeekStart: periodKey)?.title ?? "\(periodKey) 周报"
        case .monthly:
            return model.store.monthlyReport(forMonthKey: periodKey)?.title ?? "\(periodKey) 月报"
        }
    }

    private var savedContent: String {
        if isCurrentActivePeriod, model.hasReportContent {
            return model.reportContent
        }
        switch periodKind {
        case .weekly:
            return model.store.report(forWeekStart: periodKey)?.content ?? ""
        case .monthly:
            return model.store.monthlyReport(forMonthKey: periodKey)?.content ?? ""
        }
    }

    private var savedHours: Double {
        if isCurrentActivePeriod {
            return model.totalHours
        }
        switch periodKind {
        case .weekly:
            return model.store.report(forWeekStart: periodKey)?.totalHours ?? 0
        case .monthly:
            return model.store.monthlyReport(forMonthKey: periodKey)?.totalHours ?? 0
        }
    }

    private var targetPluginID: String {
        periodKind == .weekly ? ReportPlugin.pluginID : MonthlyReportPlugin.pluginID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: periodKind == .weekly ? "doc.text" : "doc.richtext")
                    .font(DS.font(13, .semibold))
                    .foregroundStyle(DS.brand)
                Text(savedTitle)
                    .font(DS.font(14, .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                if savedHours > 0 {
                    Text("\(hoursText(savedHours))h")
                        .font(DS.font(11.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(DS.toggle)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DS.toggle.opacity(0.12), in: .capsule)
                }

                Spacer(minLength: 6)

                Button {
                    Task { await regenerate() }
                } label: {
                    if operating || model.isGenerating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("重新生成", systemImage: "arrow.clockwise")
                            .font(DS.font(12))
                    }
                }
                .buttonStyle(.dsSecondary)
                .controlSize(.small)
                .disabled(operating || model.isGenerating)

                if !savedContent.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(savedContent, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(DS.font(12))
                    }
                    .buttonStyle(.dsSecondary)
                    .controlSize(.small)
                }

                if model.isTitaConfigured {
                    Button {
                        Task {
                            await activatePeriod()
                            model.openActiveTitaInBrowser()
                        }
                    } label: {
                        Label("Tita", systemImage: "paperplane")
                            .font(DS.font(12))
                    }
                    .buttonStyle(.dsSecondary)
                    .controlSize(.small)
                }

                Button {
                    model.context.openPlugin(targetPluginID)
                    Task { await activatePeriod() }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(DS.font(12))
                }
                .buttonStyle(.dsGhost)
                .help("在\(periodKind.displayName)页面打开完整视图")
            }

            if let err = model.errorMessage, isCurrentActivePeriod {
                DSBanner(.danger, err)
            }

            if savedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Text("当前周期尚未生成\(periodKind.displayName)内容。")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    Button("立即生成") {
                        Task { await regenerate() }
                    }
                    .buttonStyle(.dsPrimary)
                    .controlSize(.small)
                    .disabled(operating || model.isGenerating)
                }
                .padding(10)
                .background(DS.well, in: .rect(cornerRadius: 8))
            } else {
                let previewLimit = 700
                let isLong = savedContent.count > previewLimit
                let displayContent = (!expanded && isLong)
                    ? String(savedContent.prefix(previewLimit)) + "\n\n…"
                    : savedContent

                VStack(alignment: .leading, spacing: 8) {
                    DSMarkdownView(text: displayContent)
                        .padding(10)
                        .background(DS.well.opacity(0.55), in: .rect(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(DS.border) }

                    if isLong {
                        Button(expanded ? "收起完整内容" : "展开完整\(periodKind.displayName)") {
                            withAnimation(.snappy(duration: 0.16)) {
                                expanded.toggle()
                            }
                        }
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.brand)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DS.borderStrong) }
    }

    private func activatePeriod() async {
        switch periodKind {
        case .weekly:
            if let range = WeekRange.fromStartDateString(periodKey) {
                await model.selectWeek(range)
            }
        case .monthly:
            if let range = MonthRange.fromMonthKey(periodKey) {
                await model.selectMonth(range)
            }
        }
    }

    private func regenerate() async {
        operating = true
        defer { operating = false }
        await activatePeriod()
        await model.refreshLogs()
        await model.generate()
    }

    private func hoursText(_ h: Double) -> String {
        h == h.rounded() ? String(Int(h)) : String(format: "%.1f", h)
    }
}
