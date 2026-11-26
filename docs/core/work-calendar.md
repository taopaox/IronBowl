# 工作日历（`WorkCalendar`）

[`WorkCalendar.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Calendar/WorkCalendar.swift) 统一管理每周工作日、上下班与午休时间、默认日工时、国家法定节假日缓存以及用户手动调休标记。

## 上下班与默认工时

| 设置键 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `work.weekdays` | `[2, 3, 4, 5, 6]` | `Calendar.weekday`（1=周日，2..6=周一至周五） |
| `work.start` | `"09:00"` | 上班时间 |
| `work.end` | `"18:00"` | 下班时间 |
| `work.lunchMinutes` | `60` | 午休时长（分钟） |
| `work.flexMinutes` | `30` | 弹性时间（分钟），`0` 表示不弹性 |

- **`defaultWorkHours`**：计算公式为 $\max(0, (\text{下班分钟} - \text{上班分钟} - \text{午休分钟}) / 60)$，默认 8 小时。
- **`workEnd(on:)`**：返回指定日期的正常下班 `Date`（仅含弹性规则顺延，不含加班），专供禅道日志「正常/加班提交拆条分界线」使用。当天有上班打卡记录时按弹性规则顺延（见下节），否则就是 `work.end`。
- **`overtimeHours(on:)` / `setOvertimeHours(_:on:)`**：读写指定日期的计划加班小时数（按 `0.5h` 步进限制在 `0...12`，`<= 0` 时清除），持久化在核心数据库 `dailyOvertime` 表（`core.v4` 迁移），写入后通过 `com.taopaox.ironbowl.holidaysDidChange` 通知跨进程刷新。
- **`effectiveWorkEnd(on:)` / `offWorkTimeText(on:)`**：在 `workEnd(on:)` 的基础上顺延当日 `overtimeHours(on:)` 小时，得到实际下班时刻（及格式化文字，跨零点时显示 `次日 HH:mm`），供主工作台侧栏「距下班倒计时」、首页「下班卡」、菜单栏「离下班还有多久」以及禅道日志工时卡「XX:XX 下班」标签使用。
- **`onWorkTimeText(on:)`**：返回当日上班时间文字，有打卡记录时显示实际打卡时间（`HH:mm`），否则显示配置的固定上班时间（`work.start`），供侧栏今日卡片展示。
- **`workStart(on:)`**：同样按弹性偏移折算后的上班时刻，侧栏今日卡片的下班进度条以它为起点。
- **`scheduleText(on:)`**：上下班说明文字，无加班时有打卡为「打卡 08:29 · 17:29 下班」、无打卡为「08:30–17:30」；设置加班后同步顺延下班时间并追加「（加班 Xh）」，用于首页下班卡与设置页。

## 弹性上下班与钉钉考勤

适用于「早到早走、晚到晚走」的弹性工时（例如规定 08:30–17:30、弹性 30 分钟：8:00 到 17:00 走，9:00 到 18:00 走）。

- **弹性偏移 `flexOffset(clockIn:plannedStart:flexMinutes:)`**：上班打卡按分钟计（忽略秒），与 `work.start` 的差值限制在 ±`work.flexMinutes` 内；`workEnd` / `workStart` 都加上这个偏移。早于最早时间按最早算，晚于最晚时间按最晚算。
- **打卡数据**：存于 `attendanceClockIn` 表（迁移 `core.v3`），`clockIn(on:)` 读取，`setClockIn(_:on:source:)` 写入或清除，写入后通过 `com.taopaox.ironbowl.holidaysDidChange` 通知另一个进程重新 `reload()`。
- **钉钉 CLI 读取**：[`DingTalkAttendance.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Calendar/DingTalkAttendance.swift) 调用钉钉官方命令行工具 [dws（DingTalk Workspace CLI）](https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli)，全部只读：
  1. `dws auth status --format json` 取当前登录账号的 `user_id`（进程内缓存）；
  2. `dws attendance +check-result --users <userId> --start <日期> --end <日期> --format json`，在 `data.records` 中取 `checkType == "OnDuty"` 且有 `userCheckTime`（毫秒时间戳）的最早一条作为上班打卡；`timeResult == "NotSigned"` 视为未打卡。
- **同步时机 `syncAttendanceIfNeeded(now:)`**：主工作台启动时与每 30 秒的时钟里调用；仅在开启钉钉同步、当天是工作日、当天还没有打卡记录、处于「`work.start` − 弹性」到「`effectiveWorkEnd` + 弹性」之间才执行 `syncAttendance(for:)`。普通失败 5 分钟后重试，需要用户处理的问题 30 分钟后重试；拿到当天打卡后不再查询。
- **状态**：`isSyncingAttendance`、`attendanceIssue`（`DingTalkAttendanceError?`，成功后清空）、`attendanceError`（其文字描述）、`attendanceLastSync` 供设置页与首页展示。

### 容错

任何同步失败都只记录在 `attendanceIssue`，不写入打卡表，`workEnd` / `workStart` 自动回落到固定的 `work.start` / `work.end`。`DingTalkAttendance.classifyFailure(status:stdout:stderr:)` 解析 dws 失败输出（`{"ok":false,"error":{"type"/"category":…,"message":…}}`，可能在 stdout 或 stderr）并归类：

| `DingTalkAttendanceError` | 触发条件 | 需要用户处理（`needsUserAction`） |
| :--- | :--- | :--- |
| `.missingExecutable` | 登录 shell 找不到 `dws`；配置的路径失效时先自动重新查找，仍找不到则清空 `attendance.dingtalk.path` | 是 |
| `.nodeMissing` | npm 版 dws 是 node 脚本，退出码 127 / `env: node: No such file or directory` | 是 |
| `.notLoggedIn` | `auth status` 返回 `authenticated:false`，或错误 `category == "auth"`、消息含 access token / refresh token / 未登录 等 | 是 |
| `.noPermission` | 消息含 permission / forbidden / 无权限 / 权限不足 | 是 |
| `.network` | 消息含 dial tcp / no such host / connection refused / timeout 等 | 否 |
| `.timedOut` | dws 进程超时（auth 30 秒、考勤查询 45 秒） | 否 |
| `.cliFailed` / `.badOutput` | 其他失败或输出不是 JSON | 否 |

- 失败后清掉缓存的 userId，下次重新执行 `dws auth status` 确认账号。
- 自动同步遇到 `needsUserAction` 的问题时回调 `onAttendanceIssue`（同一天同类问题只回调一次）；主工作台 `AppModel.showAttendanceIssue(_:)` 弹出右上角提醒卡片（`core.attendance.issue`），提供「去安装 / 去登录」「查看设置」「关闭同步」。
- 首页下班卡在这种情况下显示「… · 钉钉同步不可用」。
- `DingTalkAttendance.openSetupInTerminal()` 在临时目录生成 `ironbowl-dws-setup.command` 并用「终端」打开：没装 dws 时先执行 `npm install -g dingtalk-workspace-cli`，再执行 `dws auth login`（扫码 / 浏览器授权需要交互）。设置页「在终端安装并登录」「在终端登录」按钮同样调用它。

| 设置键 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `attendance.dingtalk.enabled` | `false` | 是否通过 dws 自动同步每天的上班打卡 |
| `attendance.dingtalk.path` | `""` | dws 程序路径，留空时用登录 shell `command -v dws` 自动查找并回填 |

设置入口：设置 →「工作时间」页的「弹性时间」行与「钉钉考勤」分区（`WorkTimeSettings` / `DingTalkAttendanceSettings`，位于 [`SettingsView.swift`](../../Apps/IronBowl/SettingsView.swift)）。使用前需安装 `npm install -g dingtalk-workspace-cli` 并在终端执行 `dws auth login` 登录。

## 日期类型判定（`dayInfo(_:)`）

返回 `DayInfo(kind:name:)`，其 `isWorkday` 在 `.workday` 与 `.makeupWorkday` 时为 `true`。判定优先级从高到低：

1. **手动标记（`holidayOverride` 表）**：用户通过 `setOverride(_:isOffDay:note:)` 标为放假或补班（最高优先级）。
2. **法定节假日缓存（`holiday` 表）**：来自第三方数据源的放假（`.holiday`）或调休补班（`.makeupWorkday`）。
3. **常规星期规则**：依据 `work.weekdays` 判断为 `.workday` 或 `.weekend`。

## 节假日数据源与更新策略

| `HolidaySource` (`holiday.source`) | 说明 |
| :--- | :--- |
| `.holidayCNjsDelivr`（默认） | `cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/<year>.json` |
| `.holidayCNGitHub` | `raw.githubusercontent.com/NateScarlet/holiday-cn/master/<year>.json` |
| `.timor` | `timor.tech/api/holiday/year/<year>` |
| `.manual` | 仅手动标记，不联网 |

更新频率 `holiday.frequency` 支持 `.yearly`（默认，拉取当年和次年数据，12 月会补查次年）、`.monthly`（超过 30 天刷新）与 `.manualOnly`（仅初次或手动点「立即更新」时拉取）。数据变更后通过 `DistributedNotificationCenter`（`com.taopaox.ironbowl.holidaysDidChange`）通知主工作台与独立版万年历同步刷新。
