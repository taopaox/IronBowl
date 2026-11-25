import IronBowlKit
import SwiftUI

struct ReportSettingsView: View {
    let model: WeeklyReportModel
    var periodKind: ReportPeriodKind = .weekly

    var body: some View {
        let s = model.settings
        DSSection("通用偏好") {
            DSRow("默认报告风格", description: "决定生成周报与月报时的组织结构与语气。") {
                DSPicker(
                    selection: s.binding(ReportKeys.style),
                    options: WeeklyReportStyle.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    }
                )
            }
            DSRow("包含未提交草稿", description: "查询本周或本月每日日报时，一并纳入禅道日志页里尚未提交的本地草稿。") {
                DSToggle(isOn: s.binding(ReportKeys.includeDrafts))
            }
            DSRow("附带工时统计", description: "在周报/月报提示词和本地汇总结果中附带总工时与加班时长。") {
                DSToggle(isOn: s.binding(ReportKeys.includeHours))
            }
        }

        if periodKind == .weekly {
            DSSection(
                "周报生成提示词",
                footer: "占位符：{{weekRange}} 周次与日期区间，{{totalHours}} 本周工时汇总，{{styleInstruction}} 风格要求，{{dailyLogs}} 本周每日日报，{{extraNotes}} 补充说明。"
            ) {
                DSBlockRow {
                    TextEditor(text: s.binding(ReportKeys.prompt))
                        .font(DS.mono(13.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                }
                DSRow("恢复默认周报提示词") {
                    Button("恢复默认") {
                        s[ReportKeys.prompt] = WeeklyReportGenerator.defaultPrompt
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        } else {
            DSSection(
                "月报生成提示词",
                footer: "占位符：{{monthRange}} 月份与日期区间，{{totalHours}} 本月工时汇总，{{styleInstruction}} 风格要求，{{dailyLogs}} 本月每日日报，{{weeklyReports}} 本月已有周报参考，{{extraNotes}} 补充说明。"
            ) {
                DSBlockRow {
                    TextEditor(text: s.binding(ReportKeys.monthlyPrompt))
                        .font(DS.mono(13.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 240)
                }
                DSRow("恢复默认月报提示词") {
                    Button("恢复默认") {
                        s[ReportKeys.monthlyPrompt] = WeeklyReportGenerator.defaultMonthlyPrompt
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        }
    }
}
