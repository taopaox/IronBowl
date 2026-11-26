import AppKit
import IronBowlKit
import SwiftUI

/// T3 Code 风格输出详情视图：按详略级别展示命令、工具、思考、文件改动与原始事件流。
struct HomeChatActivityView: View {
    let message: ChatMessage
    let detailLevel: ChatOutputDetailLevel

    @State private var userOverrideExpanded: Bool?
    @State private var showRawEvents = false
    @State private var showHiddenSuccess = false
    @State private var copiedRaw = false

    private var isStreaming: Bool { message.status == .streaming }

    private var hasFailure: Bool {
        message.status == .failed || message.activities.contains { $0.status == .failed || $0.kind == .error }
    }

    private var isExpanded: Bool {
        if let userOverrideExpanded { return userOverrideExpanded }
        switch detailLevel {
        case .all:
            return true
        case .hideSuccessful:
            return isStreaming || hasFailure
        case .zen:
            return hasFailure && !isStreaming
        }
    }

    private var visibleActivities: [ChatActivityItem] {
        guard detailLevel == .hideSuccessful, !isStreaming, userOverrideExpanded == nil, !showHiddenSuccess else {
            return message.activities
        }
        return message.activities.filter { $0.status != .completed }
    }

    private var hiddenSuccessCount: Int {
        max(0, message.activities.count - visibleActivities.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            if isExpanded {
                if !visibleActivities.isEmpty {
                    Divider().overlay(DS.border)
                    VStack(spacing: 0) {
                        ForEach(Array(visibleActivities.enumerated()), id: \.element.id) { index, item in
                            ActivityRowView(item: item)
                            if index < visibleActivities.count - 1 {
                                Divider().overlay(DS.border).padding(.leading, 34)
                            }
                        }
                    }
                }

                if hiddenSuccessCount > 0 {
                    Divider().overlay(DS.border)
                    Button {
                        showHiddenSuccess = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                            Text("显示已折叠的 \(hiddenSuccessCount) 个成功步骤")
                        }
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showRawEvents, !message.rawEvents.isEmpty {
                Divider().overlay(DS.border)
                rawEventsPanel
            }
        }
        .background(DS.well.opacity(0.65), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hasFailure ? DS.danger.opacity(0.35) : DS.border)
        }
        .onChange(of: detailLevel) { _, _ in
            userOverrideExpanded = nil
            showHiddenSuccess = false
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    userOverrideExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Text(message.activitySummaryText)
                        .font(DS.font(12.5, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    if let duration = message.durationSeconds, !isStreaming {
                        Text(String(format: "%.1fs", duration))
                            .font(DS.font(11))
                            .monospacedDigit()
                            .foregroundStyle(DS.textTertiary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(DS.font(10.5, .semibold))
                        .foregroundStyle(DS.textTertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if !message.rawEvents.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        showRawEvents.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "curlybraces")
                        Text("\(message.rawEvents.count)")
                            .monospacedDigit()
                    }
                    .font(DS.font(11, .medium))
                    .foregroundStyle(showRawEvents ? DS.text : DS.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(showRawEvents ? DS.selected : DS.card, in: .rect(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(DS.border) }
                }
                .buttonStyle(.plain)
                .help("查看原始 JSONL 事件流")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isStreaming {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else if hasFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.font(12))
                .foregroundStyle(DS.danger)
        } else if message.status == .cancelled {
            Image(systemName: "stop.circle.fill")
                .font(DS.font(12))
                .foregroundStyle(DS.warning)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(DS.font(12))
                .foregroundStyle(DS.success)
        }
    }

    private var rawEventsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("原始事件流（最近 \(message.rawEvents.count) 行）")
                    .font(DS.font(11.5, .medium))
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                Button {
                    copyText(message.rawEvents.joined(separator: "\n"))
                    copiedRaw = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedRaw = false
                    }
                } label: {
                    Label(copiedRaw ? "已复制" : "复制全部", systemImage: copiedRaw ? "checkmark" : "doc.on.doc")
                        .font(DS.font(11))
                }
                .buttonStyle(.dsGhost)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(message.rawEvents.joined(separator: "\n"))
                    .font(DS.mono(11))
                    .foregroundStyle(DS.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DS.s(220))
            .padding(8)
            .background(DS.card, in: .rect(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
        }
        .padding(10)
    }
}

private struct ActivityRowView: View {
    let item: ChatActivityItem

    @State private var manualExpanded: Bool?
    @State private var showFullOutput = false
    @State private var copiedOutput = false

    private var hasBody: Bool {
        (item.inputText?.isEmpty == false) || (item.outputText?.isEmpty == false)
    }

    private var isExpanded: Bool {
        if let manualExpanded { return manualExpanded }
        return item.status == .running || item.status == .failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasBody else { return }
                withAnimation(.snappy(duration: 0.16)) {
                    manualExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.kind.systemImage)
                        .font(DS.font(11.5))
                        .foregroundStyle(iconColor)
                        .frame(width: 16)

                    Text(item.title)
                        .font(DS.font(12.5, .medium))
                        .foregroundStyle(DS.text)

                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DS.mono(11.5))
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    if let exitCode = item.exitCode {
                        Text("exit \(exitCode)")
                            .font(DS.mono(10.5))
                            .foregroundStyle(exitCode == 0 ? DS.success : DS.danger)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((exitCode == 0 ? DS.success : DS.danger).opacity(0.12), in: .capsule)
                    }

                    if let duration = item.durationSeconds {
                        Text(String(format: "%.2fs", duration))
                            .font(DS.font(11))
                            .monospacedDigit()
                            .foregroundStyle(DS.textTertiary)
                    }

                    rowStatusBadge

                    if hasBody {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(DS.font(10, .semibold))
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded, hasBody {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = item.inputText, !input.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind == .command ? "执行命令" : "输入参数")
                                .font(DS.font(11, .medium))
                                .foregroundStyle(DS.textTertiary)
                            Text(input)
                                .font(DS.mono(11.5))
                                .foregroundStyle(DS.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(DS.card, in: .rect(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border) }
                        }
                    }

                    if let output = item.outputText, !output.isEmpty {
                        let clipped = (!showFullOutput && output.count > 1600)
                        let displayOutput = clipped ? String(output.suffix(1600)) : output

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("输出内容")
                                    .font(DS.font(11, .medium))
                                    .foregroundStyle(DS.textTertiary)
                                if clipped {
                                    Button("显示全部（\(output.count) 字）") {
                                        showFullOutput = true
                                    }
                                    .font(DS.font(11))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(DS.brand)
                                }
                                Spacer()
                                Button {
                                    copyText(output)
                                    copiedOutput = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.2))
                                        copiedOutput = false
                                    }
                                } label: {
                                    Image(systemName: copiedOutput ? "checkmark" : "doc.on.doc")
                                        .font(DS.font(10.5))
                                        .foregroundStyle(DS.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .help("复制输出")
                            }
                            ScrollView {
                                Text(displayOutput)
                                    .font(DS.mono(11.5))
                                    .foregroundStyle(DS.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: DS.s(200))
                            .padding(8)
                            .background(DS.card, in: .rect(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border) }
                        }
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var iconColor: Color {
        switch item.status {
        case .running: DS.brand
        case .completed:
            item.kind == .error ? DS.danger : DS.textSecondary
        case .failed: DS.danger
        }
    }

    @ViewBuilder
    private var rowStatusBadge: some View {
        switch item.status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .completed:
            Image(systemName: "checkmark")
                .font(DS.font(10, .semibold))
                .foregroundStyle(DS.success)
        case .failed:
            Image(systemName: "xmark")
                .font(DS.font(10, .semibold))
                .foregroundStyle(DS.danger)
        }
    }
}

private func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
