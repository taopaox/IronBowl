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
            if periodKind == .monthly {
                DSRow("附带 Git 月度统计", description: "自动扫描代码根目录下的 Git 仓库本月提交（含净提交、合并、Bug/接口/部署分布）并注入月报。") {
                    DSToggle(isOn: s.binding(ReportKeys.includeGitStats))
                }
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
                footer: "占位符：{{monthRange}} 月份与日期区间，{{totalHours}} 本月工时汇总，{{styleInstruction}} 风格要求，{{monthlyOKR}} 本月 OKR，{{gitStats}} Git 月度统计，{{dailyLogs}} 本月每日日报，{{weeklyReports}} 本月已有周报参考，{{extraNotes}} 补充说明。"
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

            DSSection("飞书文档（lark-cli）", footer: "用于在月报页一键读取飞书子周报素材，或将生成的月报覆盖写入目标飞书文档。") {
                DSRow("lark-cli 路径", description: "留空时自动从登录 shell PATH、nvm、Homebrew 查找。") {
                    TextField("自动探测", text: s.binding(ReportKeys.feishuCLIPath))
                        .textFieldStyle(.ds)
                        .frame(width: 280)
                }
                DSRow("默认月报文档链接", description: "点击「写飞书」时自动填入的目标飞书云文档或知识库 URL。") {
                    TextField("https://...feishu.cn/wiki/... 或 /docx/...", text: s.binding(ReportKeys.feishuMonthlyDocURL))
                        .textFieldStyle(.ds)
                        .frame(width: 320)
                }
            }
        }

        DSSection("Tita 对接") {
            let statusText = model.isTitaConfigured
                ? (model.titaUserName.isEmpty ? "已保存 Cookie（点击管理或测试连接）" : "已连接：\(model.titaUserName)（租户 \(model.titaTenantID)）")
                : "尚未配置 Tita 登录凭证，支持网页登录提取或粘贴 cURL/Cookie。"
            DSRow("Tita 周报/月报推送", description: statusText) {
                Button("管理 Tita 对接") {
                    model.context.openSettings(ReportPlugin.settingsTitaID)
                }
                .buttonStyle(.dsSecondary)
            }
        }
    }
}
