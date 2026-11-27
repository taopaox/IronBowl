import IronBowlKit
import SwiftUI

struct AnnualReviewView: View {
    @Bindable var model: AnnualReviewModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    @Environment(\.isPageActive) private var isPageActive
    @State private var previewMode: PreviewMode = .preview
    @State private var showPoster = false
    @State private var showHistory = false
    @State private var confirmClear = false

    enum PreviewMode: Hashable {
        case preview, edit
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("季度与年度述职", topPadding: 8) {
                HStack(spacing: 10) {
                    DSTabs(
                        selection: Binding(
                            get: { model.scopeKind },
                            set: { model.switchScope($0) }
                        ),
                        options: ReviewScopeKind.allCases.map { ($0, $0.shortName) }
                    )
                    .padding(.leading, sidebarCollapsed ? 38 : 0)

                    HStack(spacing: 4) {
                        Button { model.shiftPeriod(-1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.dsGhost)

                        Text(model.range.title)
                            .font(DS.font(14, .semibold))
                            .monospacedDigit()
                            .frame(minWidth: DS.s(96))

                        Button { model.shiftPeriod(1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.dsGhost)

                        if !model.range.isCurrent() {
                            Button("回当前") { model.goToCurrentPeriod() }
                                .buttonStyle(.dsSecondary)
                        }
                    }
                }
            } actions: {
                Button {
                    showHistory.toggle()
                } label: {
                    Label("历史 (\(model.recentReviews.count))", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.dsSecondary)
                .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                    historyPopover
                }

                Button {
                    showPoster = true
                } label: {
                    Label("牛马年度账单", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.dsSecondary)

                Button {
                    Task { await model.refreshAll() }
                } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新数据", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.dsSecondary)
                .disabled(model.isLoading)
            }

            Divider().overlay(DS.border)

            HStack(spacing: 0) {
                leftSummaryPane
                    .frame(width: DS.s(320))
                    .background(DS.sidebar.opacity(0.65))

                Rectangle().fill(DS.border).frame(width: 1)

                rightEditorPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.canvas)
            }
        }
        .task(id: model.range.periodKey) {
            await refreshIfNeeded()
        }
        .onChange(of: isPageActive) { _, active in
            if active {
                Task { await refreshIfNeeded() }
            } else {
                model.saveEditsIfNeeded()
            }
        }
        .onDisappear {
            model.saveEditsIfNeeded()
        }
        .sheet(isPresented: $showPoster) {
            AnnualPosterSheet(data: model.posterData)
        }
        .alert("清空本周期述职内容？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { model.clearReview() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除「\(model.range.title)」已保存的述职正文，不影响原始日报与月报。")
        }
    }

    private func refreshIfNeeded() async {
        if !model.hasLoadedCurrentPeriod {
            model.loadLocal()
        }
        if model.shouldAutoRefresh() {
            await model.refreshAll()
        }
    }

    // MARK: - 左侧数据摘要

    private var leftSummaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    DSMetric(
                        "累计工时",
                        value: "\(WorkCalendar.hoursText(model.ledgerSummary.totalHours))h",
                        detail: "加班 \(WorkCalendar.hoursText(model.ledgerSummary.overtimeHours))h"
                    )
                    DSMetric(
                        "代码提交",
                        value: "\(model.gitStats.commitCount) 次",
                        detail: "+\(model.gitStats.addedLines) / -\(model.gitStats.deletedLines)"
                    )
                }

                DSCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("核心项目投入")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)

                        if model.ledgerSummary.projectBreakdown.isEmpty {
                            Text("该周期暂无项目工时记录")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        } else {
                            ForEach(model.ledgerSummary.projectBreakdown.prefix(6)) { proj in
                                HStack {
                                    Text(proj.projectName)
                                        .font(DS.font(12.5, .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(WorkCalendar.hoursText(proj.hours))h · \(Int((proj.share * 100).rounded()))%")
                                        .font(DS.caption.monospacedDigit())
                                        .foregroundStyle(DS.textSecondary)
                                }
                            }
                        }
                    }
                }

                DSCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("已归档月报参考")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                            Spacer()
                            Text("\(model.monthlyReports.count) 份")
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(DS.textTertiary)
                        }

                        if model.monthlyReports.isEmpty {
                            Text("暂未归档该周期内的月报，生成时将自动聚合日报与工时。")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        } else {
                            ForEach(model.monthlyReports) { rec in
                                HStack {
                                    Text(rec.monthKey)
                                        .font(DS.font(12, .medium).monospacedDigit())
                                    Text(rec.title)
                                        .font(DS.caption)
                                        .foregroundStyle(DS.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(WorkCalendar.hoursText(rec.totalHours))h")
                                        .font(DS.caption.monospacedDigit())
                                        .foregroundStyle(DS.textTertiary)
                                }
                            }
                        }
                    }
                }

                DSCard(padding: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("个人补充亮点 / 重点项目")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                        TextEditor(text: $model.extraNotes)
                            .font(DS.body)
                            .scrollContentBackground(.hidden)
                            .frame(height: 110)
                            .onChange(of: model.extraNotes) { model.scheduleAutoSave() }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 右侧编辑与生成区

    private var rightEditorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DSPicker(
                    selection: $model.style,
                    options: AnnualReviewStyle.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    }
                )

                DSPicker(
                    selection: $model.providerKind,
                    options: AIProviderKind.allCases.map {
                        DSPickerOption($0, title: $0.displayName, triggerTitle: $0.shortName)
                    }
                )

                DSTabs(selection: $previewMode, options: [
                    (.preview, "预览"),
                    (.edit, "编辑"),
                ])

                Spacer(minLength: 4)

                if model.hasContent {
                    Button(model.copied ? "已复制" : "复制") { model.copyMarkdown() }
                        .buttonStyle(.dsSecondary)

                    Button("导出 .md") { model.exportMarkdown() }
                        .buttonStyle(.dsSecondary)

                    Button {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsGhost)
                }

                Button {
                    Task { await model.generate() }
                } label: {
                    if model.isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("生成中…")
                        }
                    } else {
                        Label(model.hasContent ? "重新生成" : "生成述职", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.dsPrimary)
                .disabled(model.isGenerating)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider().overlay(DS.border)

            if let err = model.errorMessage {
                DSBanner(.warning, err)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            } else if let msg = model.message {
                DSBanner(.success, msg)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if !model.hasContent && previewMode == .preview {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(DS.font(32))
                        .foregroundStyle(DS.textTertiary)
                    Text("一键汇总 \(model.range.title) 工时、月报与 Git 提交")
                        .font(DS.rowTitle)
                        .foregroundStyle(DS.textSecondary)
                    Text("支持述职 STAR 法则、OKR 复盘与量化提纲三种风格，还能生成可导出图片的「牛马年度账单」。")
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                    Button("立即生成\(model.range.scopeKind.displayName)") {
                        Task { await model.generate() }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(model.isGenerating)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("报告标题", text: $model.reportTitle)
                        .textFieldStyle(.plain)
                        .font(DS.font(20, .semibold))
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .onChange(of: model.reportTitle) { model.scheduleAutoSave() }

                    Divider().overlay(DS.border).padding(.horizontal, 24)

                    if previewMode == .preview {
                        ScrollView {
                            DSMarkdownView(text: model.reportContent)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                        }
                    } else {
                        TextEditor(text: $model.reportContent)
                            .font(DS.mono(13.5))
                            .lineSpacing(5)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .onChange(of: model.reportContent) { model.scheduleAutoSave() }
                    }
                }
            }
        }
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("历史述职归档")
                .font(DS.sectionTitle)
            if model.recentReviews.isEmpty {
                Text("暂无已保存的季度/半年度/年度报告")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.recentReviews) { rec in
                            HStack {
                                Button {
                                    if let r = ReviewRange.fromPeriodKey(rec.periodKey) {
                                        model.selectRange(r)
                                    }
                                    showHistory = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rec.title)
                                            .font(DS.font(13, .medium))
                                            .foregroundStyle(DS.text)
                                        Text("\(rec.periodKey) · \(WorkCalendar.hoursText(rec.totalHours))h · \(rec.commitCount) commits")
                                            .font(DS.caption.monospacedDigit())
                                            .foregroundStyle(DS.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.deleteHistoryRecord(rec.periodKey)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(DS.font(11.5))
                                        .foregroundStyle(DS.danger)
                                }
                                .buttonStyle(.dsGhost)
                            }
                            .padding(8)
                            .background(DS.well, in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct AnnualReviewSettingsView: View {
    @Bindable var model: AnnualReviewModel

    var body: some View {
        let s = model.settings
        DSSection("述职与年度复盘", footer: "支持占位符 {{periodTitle}}、{{periodRange}}、{{styleInstruction}}、{{metricsSummary}}、{{projectBreakdown}}、{{gitSummary}}、{{monthlyReports}}、{{extraNotes}}。") {
            DSRow("默认述职风格", description: model.style.detail) {
                DSPicker(
                    selection: $model.style,
                    options: AnnualReviewStyle.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    }
                )
            }
            DSBlockRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI 述职提示词模板")
                            .font(DS.rowTitle)
                        Spacer()
                        Button("恢复默认") {
                            s[ReportKeys.annualPrompt] = AnnualReviewGenerator.defaultPrompt
                        }
                        .buttonStyle(.dsSecondary)
                    }
                    TextEditor(text: Binding(
                        get: { s[ReportKeys.annualPrompt] },
                        set: { s[ReportKeys.annualPrompt] = $0 }
                    ))
                    .font(DS.mono(12.5))
                    .frame(height: 180)
                    .padding(8)
                    .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                    .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
                }
            }
        }
    }
}
