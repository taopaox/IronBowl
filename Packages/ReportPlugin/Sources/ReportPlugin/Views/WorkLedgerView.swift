import IronBowlKit
import SwiftUI

struct WorkLedgerView: View {
    @Bindable var model: WorkLedgerModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    private var palette: JournalPalette {
        JournalPalette(preset: model.context.settings[JournalKeys.paperPreset])
    }

    var body: some View {
        let p = palette
        VStack(spacing: 0) {
            DSPageHeader("牛马账本", topPadding: 8) {
                HStack(spacing: 10) {
                    DSTabs(
                        selection: $model.mode,
                        options: LedgerPeriodMode.allCases.map { ($0, $0.rawValue) }
                    )
                    .padding(.leading, sidebarCollapsed ? 38 : 0)

                    HStack(spacing: 4) {
                        Button { model.shiftPeriod(-1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.dsGhost)

                        Text(model.periodTitle)
                            .font(DS.font(14, .semibold))
                            .monospacedDigit()
                            .frame(minWidth: DS.s(84))

                        Button { model.shiftPeriod(1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.dsGhost)

                        if !model.isCurrentPeriod {
                            Button(model.mode == .monthly ? "回本月" : "回今年") {
                                model.goToCurrentPeriod()
                            }
                            .buttonStyle(.dsSecondary)
                        }
                    }
                }
            } actions: {
                Toggle("含草稿", isOn: $model.includeDrafts)
                    .toggleStyle(.checkbox)
                    .font(DS.caption)

                if model.isDingTalkAttendanceEnabled {
                    Button {
                        Task { await model.syncPeriodAttendance() }
                    } label: {
                        if model.isSyncingAttendance {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("同步钉钉考勤", systemImage: "person.badge.clock")
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(model.isSyncingAttendance)
                }

                if model.isZentaoConfigured {
                    Button {
                        Task { await model.refreshFromZentao() }
                    } label: {
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("同步禅道", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(model.isLoading)
                }
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let err = model.remoteError {
                        DSBanner(.warning, "禅道同步失败（当前展示本地数据）：\(err)")
                    }
                    if let attErr = model.attendanceSyncError {
                        DSBanner(.warning, "钉钉考勤同步失败：\(attErr)")
                    } else if let attMsg = model.attendanceSyncMessage {
                        DSBanner(.success, attMsg)
                    }

                    metricsGrid(palette: p)

                    HStack(alignment: .top, spacing: 16) {
                        Group {
                            if model.mode == .monthly {
                                monthlyCalendarCard(palette: p)
                            } else {
                                yearlyOverviewCard(palette: p)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 16) {
                            projectBreakdownCard(palette: p)
                            attendanceAnomalyCard(palette: p)
                        }
                        .frame(width: DS.s(320))
                    }
                }
                .padding(28)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.canvas)
        .task(id: "\(model.mode.rawValue)-\(model.periodTitle)") {
            model.loadLocal()
            if model.isZentaoConfigured && !model.syncedFromZentao {
                await model.refreshFromZentao()
            }
        }
    }

    // MARK: - 顶部 4 联指标

    private func metricsGrid(palette p: JournalPalette) -> some View {
        let s = model.summary
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
            DSMetric(
                "累计工时",
                value: "\(WorkCalendar.hoursText(s.totalHours))h",
                detail: "正常 \(WorkCalendar.hoursText(s.normalHours))h · 加班 \(WorkCalendar.hoursText(s.overtimeHours))h"
            )
            DSMetric(
                "加班账单",
                value: "\(WorkCalendar.hoursText(s.overtimeHours))h",
                detail: s.overtimeDaysCount > 0 ? "共加班 \(s.overtimeDaysCount) 天" : "暂无加班记录",
                valueColor: s.overtimeHours > 0 ? p.stampPurple : DS.text
            )
            DSMetric(
                "出勤与填报",
                value: "\(s.loggedDaysCount)/\(s.expectedWorkdaysCount) 天",
                detail: s.clockInDaysCount > 0 ? "已同步 \(s.clockInDaysCount) 天钉钉打卡" : "可开启钉钉打卡自动同步",
                valueColor: s.loggedDaysCount > 0 ? DS.success : DS.text
            )
            DSMetric(
                "在岗 vs 填报",
                value: s.clockOutDaysCount > 0 ? "\(WorkCalendar.hoursText(s.actualStayHours))h" : (s.averageClockInText ?? "—"),
                detail: s.clockOutDaysCount > 0
                    ? "填报 \(WorkCalendar.hoursText(s.totalHours))h · \(s.clockOutDaysCount) 天有下班卡"
                    : (s.earliestClockInText.map { "最早 \($0)" } ?? "暂无上下班打卡对")
            )
        }
    }

    // MARK: - 月度热力日历

    private func monthlyCalendarCard(palette p: JournalPalette) -> some View {
        let cal = Calendar(identifier: .gregorian)
        let firstWeekday = model.month.startDate
        let weekday = cal.component(.weekday, from: firstWeekday) // 1 = Sun, 2 = Mon ...
        let leadEmpty = (weekday - 2 + 7) % 7
        let headers = ["一", "二", "三", "四", "五", "六", "日"]

        return DSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(model.month.title)出勤与工时热力")
                        .font(DS.sectionTitle)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot(color: DS.success.opacity(0.22), text: "正常工时")
                        legendDot(color: p.stampPurple.opacity(0.25), text: "含加班")
                    }
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                }

                HStack(spacing: 4) {
                    ForEach(headers, id: \.self) { name in
                        Text("周\(name)")
                            .font(DS.caption)
                            .foregroundStyle((name == "六" || name == "日") ? DS.danger : DS.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(0..<leadEmpty, id: \.self) { _ in
                        Color.clear.frame(height: DS.s(64))
                    }
                    ForEach(model.summary.dailyCells) { day in
                        dayCell(day, palette: p)
                    }
                }
            }
        }
    }

    private func dayCell(_ day: LedgerDayStat, palette p: JournalPalette) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        let bg: Color = {
            if day.overtimeHours > 0 {
                return p.stampPurple.opacity(0.14)
            }
            if day.normalHours >= 8 {
                return DS.success.opacity(0.18)
            }
            if day.normalHours > 0 {
                return DS.success.opacity(0.09)
            }
            return day.isWorkday ? DS.well : .clear
        }()

        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(day.dayNumber)")
                    .font(DS.font(12, isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(day.isWorkday ? DS.text : DS.textTertiary)
                Spacer(minLength: 2)
                if day.overtimeHours > 0 {
                    Text("+\(WorkCalendar.hoursText(day.overtimeHours))h")
                        .font(DS.font(9.5, .bold).monospacedDigit())
                        .foregroundStyle(p.stampPurple)
                }
            }

            if day.totalHours > 0 {
                Text("\(WorkCalendar.hoursText(day.totalHours))h")
                    .font(DS.font(12.5, .semibold).monospacedDigit())
                    .foregroundStyle(day.overtimeHours > 0 ? p.stampPurple : DS.success)
            } else {
                Text(day.isWorkday ? "—" : "休")
                    .font(DS.font(11))
                    .foregroundStyle(DS.textTertiary)
            }

            Spacer(minLength: 0)

            if let ci = day.clockInText {
                Text(day.clockOutText.map { "\(ci)-\($0)" } ?? "打 \(ci)")
                    .font(DS.font(9).monospacedDigit())
                    .foregroundStyle(day.anomalies.isEmpty ? DS.textSecondary : DS.danger)
                    .lineLimit(1)
            } else if !day.anomalies.isEmpty {
                Text(day.anomalies.joined(separator: "/"))
                    .font(DS.font(9))
                    .foregroundStyle(DS.danger)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: DS.s(64), alignment: .topLeading)
        .background(bg, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? DS.brand : DS.border, lineWidth: isToday ? 1.5 : 1)
        }
    }

    // MARK: - 年度概览

    private func yearlyOverviewCard(palette p: JournalPalette) -> some View {
        let maxMonthHours = max(1, model.summary.monthlyBuckets.map(\.totalHours).max() ?? 1)
        return DSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(String(model.year))年各月工时与加班分布")
                    .font(DS.sectionTitle)
                    .foregroundStyle(DS.textSecondary)

                VStack(spacing: 8) {
                    ForEach(model.summary.monthlyBuckets) { bucket in
                        HStack(spacing: 10) {
                            Text(bucket.title)
                                .font(DS.font(13, .medium).monospacedDigit())
                                .frame(width: DS.s(42), alignment: .leading)

                            GeometryReader { geo in
                                let normalRatio = min(1, bucket.normalHours / maxMonthHours)
                                let otRatio = min(1 - normalRatio, bucket.overtimeHours / maxMonthHours)
                                HStack(spacing: 1) {
                                    if normalRatio > 0 {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(DS.success.opacity(0.75))
                                            .frame(width: max(4, geo.size.width * normalRatio))
                                    }
                                    if otRatio > 0 {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(p.stampPurple.opacity(0.85))
                                            .frame(width: max(4, geo.size.width * otRatio))
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .frame(height: DS.s(14))
                            .background(DS.well, in: .rect(cornerRadius: 4))

                            Text("\(WorkCalendar.hoursText(bucket.totalHours))h")
                                .font(DS.font(12.5, .semibold).monospacedDigit())
                                .frame(width: DS.s(54), alignment: .trailing)

                            Text(bucket.overtimeHours > 0 ? "加班 \(WorkCalendar.hoursText(bucket.overtimeHours))h" : "\(bucket.loggedDaysCount)/\(bucket.expectedWorkdaysCount)天")
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(bucket.overtimeHours > 0 ? p.stampPurple : DS.textTertiary)
                                .frame(width: DS.s(76), alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 右侧项目投入分布

    private func projectBreakdownCard(palette p: JournalPalette) -> some View {
        DSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("项目工时投入")
                    .font(DS.sectionTitle)
                    .foregroundStyle(DS.textSecondary)

                if model.summary.projectBreakdown.isEmpty {
                    Text("该周期内还没有已记录工时")
                        .font(DS.body)
                        .foregroundStyle(DS.textTertiary)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.summary.projectBreakdown) { proj in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(proj.projectName)
                                        .font(DS.font(13.5, .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(WorkCalendar.hoursText(proj.hours))h · \(Int((proj.share * 100).rounded()))%")
                                        .font(DS.caption.monospacedDigit())
                                        .foregroundStyle(DS.textSecondary)
                                }

                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(DS.brand)
                                        .frame(width: max(4, geo.size.width * proj.share))
                                }
                                .frame(height: 6)
                                .background(DS.well, in: .rect(cornerRadius: 3))
                            }
                        }
                    }
                }

                if let earliest = model.summary.earliestClockInText {
                    Divider().overlay(DS.border)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("作息极值")
                            .font(DS.caption)
                            .foregroundStyle(DS.textTertiary)
                        Text("最早打卡：\(earliest)")
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                        if let latest = model.summary.latestOffWorkText {
                            Text("最晚下班：\(latest)")
                                .font(DS.caption.monospacedDigit())
                                .foregroundStyle(p.stampPurple)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 考勤异常与漏卡核对

    private func attendanceAnomalyCard(palette p: JournalPalette) -> some View {
        let anomalies = model.summary.anomalyDays
        return DSCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("考勤异常与漏卡核对")
                        .font(DS.sectionTitle)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    if !anomalies.isEmpty {
                        Text("\(anomalies.count) 天")
                            .font(DS.font(11, .semibold).monospacedDigit())
                            .foregroundStyle(DS.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.danger.opacity(0.12), in: .capsule)
                    }
                }

                if model.summary.clockInDaysCount == 0 && anomalies.isEmpty {
                    Text(model.isDingTalkAttendanceEnabled ? "点击右上角「同步钉钉考勤」可核对本周期漏卡、迟到与早退情况。" : "可在「设置 → 工作时间」开启钉钉考勤同步，自动核对漏卡与在岗时长。")
                        .font(DS.caption)
                        .foregroundStyle(DS.textTertiary)
                } else if anomalies.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(DS.success)
                        Text("已核对 \(model.summary.clockInDaysCount) 天考勤，全勤无缺卡或异常。")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(anomalies.prefix(10)) { item in
                            HStack(spacing: 8) {
                                Text(item.dateString)
                                    .font(DS.font(12, .medium).monospacedDigit())
                                    .foregroundStyle(DS.text)
                                Spacer()
                                Text(item.reasons)
                                    .font(DS.caption)
                                    .foregroundStyle(DS.danger)
                            }
                        }
                        if anomalies.count > 10 {
                            Text("另有 \(anomalies.count - 10) 天异常未展开")
                                .font(DS.caption)
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(text)
        }
    }
}
