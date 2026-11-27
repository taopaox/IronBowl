# 禅道日志插件（`ZentaoLogPlugin`）

`ZentaoLogPlugin`（`Packages/ZentaoLogPlugin`）是 IronBowl 的核心效率插件，打通「本地 Git 提交扫描 → 当日工时与加班计划 → AI/规则拆条生成 → 禅道企业版/开源版回写校验 → 定时弹窗提醒」全流程。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `ZentaoLogPlugin.swift` | `ZentaoLogPlugin`, `LogReminderScheduler` | 插件入口（左侧栏归入「汇报」分组并显示为「日报」，设置与菜单栏保留「禅道日志」）、首页快捷操作/一句话记日志、对话意图路由、菜单栏状态与提醒调度 |
| `ZentaoChatHandler.swift` | `ZentaoChatHandler`, `ZentaoChatIntent` | 识别首页对话中的生成/查看日报及 `记日志：` 指令（过滤代码/调试类提问） |
| `Views/ZentaoDailyChatCard.swift` | `ZentaoDailyChatCard` | 在首页聊天流内直接渲染并操作的日报卡片（切换禅道任务、调整工时、修改内容、记加班、重新生成与提交禅道） |
| `LogModel.swift` | `LogModel` | `@Observable` 业务状态：扫描、任务/已写工时同步、草稿读写、当日工时/加班、提交与 AI 解析 |
| `DailyLogQuery.swift` | `ZentaoDailyLogService`, `DailyLogItem`, `DailyLogRangeResult` | 面向周报等跨天插件的只读区间日报查询服务（融合禅道远端、本地已提交与未提交草稿并去重） |
| `Git/GitScanner.swift` | `GitScanner`, `RepoActivity`, `GitCommit`, `RepoWorkspaceStatus` | 多层级发现 Git 仓库、按作者邮箱和本地当天 00:00–24:00 扫描提交（跨仓库按哈希去重），并支持巡检未提交改动与未推送提交（`workspaceStatus`） |
| `Draft/DraftGenerator.swift` | `DraftGenerator`, `DraftEntry`, `DraftInput` | 按工作日/下班时间拆条、权重分配工时、AI 结构化生成与失败拼接兜底、剩余工时递减 |
| `Zentao/ZentaoClient.swift` | `ZentaoClient`, `ZentaoTask`, `ZentaoEstimate` | 禅道 PATH_INFO `.json` 客户端（登录、自动重登、企业版 `effort` 与开源版 `recordEstimate` 兼容、提交回查） |
| `Store/LogSettings.swift` | `LogKeys`, `LogMigrations`, `LogStore` | SQLite 持久化（仓库映射、本地提交记录、上次任务、未提交草稿） |
| `Views/LogView.swift` | `LogView`, `JournalDayRingStrip`, `JournalWorkHoursCard`, `JournalCommitSlipCard`, `JournalDraftCard`, `JournalRecordedCard`, `OvertimeSheet` | 双页活页手账主视图（左页撕历、7 天圆环打卡条、三段工时刻度与 Git 小票摘录；右页橡皮印章、荧光笔重点标黄、待提交草稿与已入账记录） |
| `Views/LogSettingsView.swift` | `ZentaoAccountSettings`, `RepoSettings`, `GenerateSettings`, `ReminderSettings` | 四个设置页：禅道账号、仓库映射、生成提示词与工时、提醒时间与样式 |

## 当日需填工时与「正常 + 加班」拆条生成

1. **手账式当日工时刻度与快捷加班设置**：
   - `LogView` 使用 `IronBowlKit` 的 `JournalSpreadShell` 呈现双页活页手账（支持「暖米手账 / 清爽象牙」纸感切换，以及右缘「日报 / 周报 / 月报」索引签一键翻页）。
   - 左页展示手账撕历头（日期、工作日/休息日标签、预计下班时刻 `WorkCalendar.offWorkTimeText(on:)` 与剩余缺口徽章）、`JournalDayRingStrip` 7 天圆环打卡条、`JournalWorkHoursCard`（`JournalProgressBar` 三段彩色工时刻度条 + `+1h`/`+2h`/`+3h`/`+4h` 快捷加班按钮与「清除」）、当日待办联动卡 `JournalTodoCard`（展示当天相关待办，支持勾选及一键带入草稿）、下班前仓库巡检卡 `JournalGitInspectionCard`（提示未提交/未 Push 代码并可在提交禅道前二次提醒）以及按仓库分组的 Git 提交小票（支持点击 `+ 摘录` 调用 `LogModel.addDraftFromCommit(activity:commit:)` 直接生成一条草稿）；菜单栏亦提供 `zentao.gitDirty` 展示待推送仓库数。
   - 右页右上角展示 `JournalStampBadge` 橡皮印章（待提交草稿 / 已入账 / 待填报），顶部配备 `JournalSpreadShell` 状态胶囊、右页贯通状态色带与 `JournalStatusBanner` 横幅（明显区分「今日未写」「草稿待交」「今日已写」与「休息日」），提供单一聚焦操作栏（`生成草稿`、`手写一条`、朱红主按钮 `盖章提交禅道`）；同时通过 `ZentaoLogPlugin.sidebarBadge` 在左侧栏显示「今日未写」或「草稿」角标；每条草稿与已入账记录支持通过 `JournalHighlight.toggle` 使用荧光笔标黄重点，并自动同步至周报/月报的每日摘录高亮显示。
   - 每日加班时长通过 `WorkCalendar.setOvertimeHours(_:on:)` 持久化到核心表 `dailyOvertime`（`core.v4`），选择或清除加班后会立即顺延或恢复左页工时刻度、侧栏 `TodayCard`、首页下班卡及菜单栏「离下班还有多久」的实际下班时间。
2. **正常上班时间与加班工时分别生成独立日志**（`DraftGenerator.generate`）：
   - 手动生成、对话卡片重新生成和定时任务共用同一规则。保留手写、一句话记录、手动摘录和编辑过的草稿，旧版草稿也保留。扣除这些条目的工时，并跳过已被保留条目引用的 Git 提交。生成期间若草稿有变动，本次结果作废，可再次生成。
   - 分别扣减当天已记录的正常工时与加班工时，得到独立的 `normalBudget` 和 `overtimeBudget`，且正常草稿与加班草稿分批构建，**同一任务在正常与加班时段不会合并成同一条**。
   - 当同时存在 `normalBudget > 0` 与 `overtimeBudget > 0` 时，仍按正常下班时刻 `WorkCalendar.workEnd(on:)` 拆分提交（`splitActivities`）：
     - 下班前后均有提交时，分别以「正常工作时段」与「加班时段」提交调用 AI，各自生成正常日志（`isOvertime = false`）与加班日志（`isOvertime = true`）。
     - 仅单侧有提交时，用全部有效提交生成正常工时日志，并基于主工作摘要合成一条独立的加班日志（`isOvertime = true`）。
   - 若正常工时已录满或休息日仅设置加班，则仅生成 `isOvertime = true` 的加班草稿。
   - 手动指定的任务剩余工时会沿用，其余待提交草稿按顺序通过 `recomputeLefts` 对同一任务逐条扣减剩余工时 `left`。

## 全局快捷记日志

饭碗运行并启用「日报」插件时，按 **Control + Option + Command + L** 可在当前桌面打开「快速记日志」，输入一句话后按回车加入当天草稿。按 Esc 取消，收起面板后可继续使用原来的应用。快捷记录不会切换日报页当前查看的日期。

- 已配置禅道账号和 AI 命令行时，复用首页「记日志」的解析，匹配任务、工作内容和工时。
- 缺少配置时可直接保存原文。面板根据数字加「小时」「分钟」或 `h` 预填工时，识别「半小时」，默认 1 小时，保存前可调整。解析失败也会保留输入，回车可按原文保存。原文草稿使用已配置的兜底任务，未配置时留待选择。
- 「设置 → 禅道日志 → 日志生成 → 快速记日志」可关闭快捷键或点「立即打开」。组合键占用时这里显示注册结果。开关为 `log.quickLogShortcut`，默认为开启。

## 禅道接口适配（`ZentaoClient`）

- 兼容企业版 biz4.x `effort` 模块与开源版 `task-recordEstimate`：登录后读取 `user.rights` 判断 `supportsEffortModule`，也可在请求响应中动态回退。
- 每次提交工时前记录该任务既有条目数，提交后立即回查 `estimates(taskID:)` 确认新工时写入成功，否则抛出 `ZentaoError.submitNotVerified`。
- 所有请求的脱敏摘要写入 `~/Library/Application Support/IronBowl/logs/zentao.log`。

## 常用设置键（`LogKeys`）

- **禅道连接**：`zentao.baseURL`、`zentao.account`、`zentao.password`、`zentao.fallbackTaskID`
- **Git 扫描**：`git.root`（默认 `/Users/yxhc/huanwei`）、`git.depth`（默认 `2`）、`git.authorEmail`、`scan.mode`（`.onDemand` / `.onDemandPlusInterval` / `.manualOnly`）、`scan.intervalMinutes`
- **生成与工时**：`log.prompt`、`log.overtimeDefaultHours`（默认 `2`）、`log.offDayOvertime`（默认 `true`）
- **提醒调度**：`reminder.times`（默认 `["18:00"]`）、`reminder.style`（默认 `.cornerCard`）、`reminder.snoozeMinutes`（默认 `15`）、`reminder.offDays`（默认 `false`）、`reminder.skipDate`

## 日志提醒设置与系统通知权限引导

- 在 `ReminderSettings`（「设置 → 禅道日志 → 日志提醒」）选择「系统通知」样式时，界面会自动检查当前 `SystemNotificationStatus` 并展示「系统通知权限」状态行（在窗口重新激活如从系统设置切回时自动刷新）：
  - 未授权（`.notDetermined`）时提供「请求权限」与「系统设置」快捷按钮；
  - 权限被拒（`.denied`）或系统通知样式被设为「无」（`.alertsDisabled`）时显示警告状态与提示条，并提供「前往设置权限 / 前往设置样式」按钮一键调用 `ReminderCenter.openSystemNotificationSettings()` 跳转 macOS「系统设置 → 通知 → 饭碗」。
- 点击「预览」调用 `LogReminderScheduler.preview(style:)`（内部走 `ReminderCenter.showAndReport(_:style:)`），在系统通知模式下会即时反馈实际投递结果（成功发送、权限未开启、样式为「无」或投递错误），避免权限缺失时点击预览毫无反应。

## 定时自动生成并提交今日日志

`ZentaoLogPlugin` 在启动时向 `context.scheduler` 注册动作 `zentao.autoSubmitLog`（「自动生成并提交今日禅道日志」），并首次自动创建默认定时任务 `builtin.zentao.dailyAutoSubmit`：

- **默认调度**：`仅工作日 17:00`（跟随 `WorkCalendar` 节假日与调休补班），错过策略为 `.runIfMissedToday`，可在「定时任务」侧边栏页面随时修改时间、周期、开关或手动试跑。
- **防重复提交校验**：执行前先联网拉取禅道最新任务列表与当天远端已记工时，并与本地 `zentaoSubmission` 合并比对；若今日已有已提交工时则自动跳过并静默记录；若联网同步失败则直接中止并报错，避免误重复提交。
- **可配边界参数**：
  - `draftStrategy`（默认 `regenerate`）：支持「保留手写修改，重新生成后提交」「直接提交已有草稿」「保留草稿并跳过」。
  - `allowFallbackOnAIFailure`（默认 `true`）：AI 生成失败时允许使用提交信息拼接结果自动提交；关闭后仅保存草稿并通知人工确认。
  - `requireMappedTask`（默认 `false`）：开启后若存在未关联项目的仓库落到兜底任务，则暂停自动提交并提醒确认。
- **无提交保护**：当日未扫描到任何 Git 提交时不会提交空日志，而是记录跳过并强制弹窗提醒用户前往日志页手动补写。

