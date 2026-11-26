# 禅道日志插件（`ZentaoLogPlugin`）

`ZentaoLogPlugin`（`Packages/ZentaoLogPlugin`）是 IronBowl 的核心效率插件，打通「本地 Git 提交扫描 → 当日工时与加班计划 → AI/规则拆条生成 → 禅道企业版/开源版回写校验 → 定时弹窗提醒」全流程。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `ZentaoLogPlugin.swift` | `ZentaoLogPlugin`, `LogReminderScheduler` | 插件入口（左侧栏归入「汇报」分组并显示为「日报」，设置与菜单栏保留「禅道日志」）、首页快捷操作/一句话记日志、菜单栏状态与提醒调度 |
| `LogModel.swift` | `LogModel` | `@Observable` 业务状态：扫描、任务/已写工时同步、草稿读写、当日工时/加班、提交与 AI 解析 |
| `DailyLogQuery.swift` | `ZentaoDailyLogService`, `DailyLogItem`, `DailyLogRangeResult` | 面向周报等跨天插件的只读区间日报查询服务（融合禅道远端、本地已提交与未提交草稿并去重） |
| `Git/GitScanner.swift` | `GitScanner`, `RepoActivity`, `GitCommit` | 多层级发现 Git 仓库、按作者邮箱和本地当天 00:00–24:00 扫描提交（跨仓库按哈希去重） |
| `Draft/DraftGenerator.swift` | `DraftGenerator`, `DraftEntry`, `DraftInput` | 按工作日/下班时间拆条、权重分配工时、AI 结构化生成与失败拼接兜底、剩余工时递减 |
| `Zentao/ZentaoClient.swift` | `ZentaoClient`, `ZentaoTask`, `ZentaoEstimate` | 禅道 PATH_INFO `.json` 客户端（登录、自动重登、企业版 `effort` 与开源版 `recordEstimate` 兼容、提交回查） |
| `Store/LogSettings.swift` | `LogKeys`, `LogMigrations`, `LogStore` | SQLite 持久化（仓库映射、本地提交记录、上次任务、未提交草稿） |
| `Views/LogView.swift` | `LogView`, `WorkHoursCard`, `DayTabs`, `DraftCard`, `RecordedLogCard`, `OvertimeSheet` | 日志主视图、当日需填工时卡、7 天切换、已写与待提交卡片 |
| `Views/LogSettingsView.swift` | `ZentaoAccountSettings`, `RepoSettings`, `GenerateSettings`, `ReminderSettings` | 四个设置页：禅道账号、仓库映射、生成提示词与工时、提醒时间与样式 |

## 当日需填工时与「正常 + 加班」拆条生成

1. **当日需填工时展示与快捷加班设置**：
   - `WorkHoursCard` 实时展示选中日期的 `targetHours = baseWorkHours + plannedOvertimeHours`（工作日取 `WorkCalendar.defaultWorkHours`，休息日基础为 `0`），并显示已写工时、还需填写的差额以及当日下班时间标签（`WorkCalendar.offWorkTimeText(on:)`）。
   - 提供 `+1h`、`+2h`、`+3h`、`+4h` 快捷胶囊按钮（再次点击同档位归零）和 `0.5h` 步进的 `DSStepper`（支持任意 `n` 小时，上限 12h）及「清除」按钮。
   - 每日加班时长通过 `WorkCalendar.setOvertimeHours(_:on:)` 持久化到核心表 `dailyOvertime`（`core.v4`），选择或清除加班后会立即顺延或恢复 `WorkHoursCard`、侧栏 `TodayCard`、首页下班卡及菜单栏「离下班还有多久」的实际下班时间，并在 `DayTabs` 未写且已设加班时标记紫色「加班 Xh」、在菜单栏「今天的工时」同步显示目标工时。
2. **正常上班时间与加班工时分别生成独立日志**（`DraftGenerator.generate`）：
   - 分别扣减当天已记录的正常工时与加班工时，得到独立的 `normalBudget` 和 `overtimeBudget`，且正常草稿与加班草稿分批构建，**同一任务在正常与加班时段不会合并成同一条**。
   - 当同时存在 `normalBudget > 0` 与 `overtimeBudget > 0` 时，仍按正常下班时刻 `WorkCalendar.workEnd(on:)` 拆分提交（`splitActivities`）：
     - 下班前后均有提交时，分别以「正常工作时段」与「加班时段」提交调用 AI，各自生成正常日志（`isOvertime = false`）与加班日志（`isOvertime = true`）。
     - 仅单侧有提交时，用全部有效提交生成正常工时日志，并基于主工作摘要合成一条独立的加班日志（`isOvertime = true`）。
   - 若正常工时已录满或休息日仅设置加班，则仅生成 `isOvertime = true` 的加班草稿。
   - 全部待提交草稿按顺序通过 `recomputeLefts` 对同一任务逐条扣减剩余工时 `left`。

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
  - `draftStrategy`（默认 `regenerate`）：支持「重新扫描并生成覆盖后提交」「直接提交已有草稿」「保留草稿并跳过」。
  - `allowFallbackOnAIFailure`（默认 `true`）：AI 生成失败时允许使用提交信息拼接结果自动提交；关闭后仅保存草稿并通知人工确认。
  - `requireMappedTask`（默认 `false`）：开启后若存在未关联项目的仓库落到兜底任务，则暂停自动提交并提醒确认。
- **无提交保护**：当日未扫描到任何 Git 提交时不会提交空日志，而是记录跳过并强制弹窗提醒用户前往日志页手动补写。

