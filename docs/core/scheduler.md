# 定时任务调度引擎（`TaskScheduler`）

[`TaskScheduler.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Scheduler/TaskScheduler.swift)、[`TaskSchedule.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Scheduler/TaskSchedule.swift) 与 [`TaskSchedulerStore.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Scheduler/TaskSchedulerStore.swift) 为工作台和各插件提供可扩展的本地定时任务持久化、调度与执行历史记录能力。

> 仅主工作台 `Apps/IronBowl` 通过 `SchedulerPlugin` 启动调度定时器；独立版万年历（`Apps/Calendar`）只持有默认未启动的 `TaskScheduler` 实例，避免双进程重复执行定时任务。

## 调度周期（`TaskScheduleKind`）

| 类型 | 说明 | 计算规则 |
| :--- | :--- | :--- |
| `.workdays` | 仅工作日 | 结合 `WorkCalendar.isWorkday(_:)`（含法定节假日与调休补班），从当前日期向后找到最早大于参考时刻的 `hour:minute` |
| `.beforeWorkEnd` | 下班前（工作日） | 结合 `WorkCalendar.isWorkday(_:)` 与 `WorkCalendar.effectiveWorkEnd(on:)`（含弹性打卡与计划加班，支持跨零点加班），提前 `minutesBeforeWorkEnd`（默认 `5` 分钟）触发 |
| `.daily` | 每天 | 每天固定 `hour:minute` |
| `.weekly` | 每周指定日期 | 按 `weekdays`（1=周日…7=周六）在指定星期几的 `hour:minute` 触发 |
| `.interval` | 每隔固定分钟 | 按 `intervalMinutes` 固定时间间隔循环触发 |

> `TaskSchedule` 解码使用向后兼容策略（`decodeIfPresent`），老数据库存量任务缺少 `minutesBeforeWorkEnd` 字段时自动回退为 `5` 分钟；调整工作时间设置、弹性时间、加班或节假日标记后会通过 `recomputeNextRuns()` 实时重算下一次触发时间。

## 错过策略与防重复机制

- **时间槽去重（`lastFiredSlot`）**：每次触发前同步持久化 `lastFiredSlot`（`yyyy-MM-dd HH:mm` 或间隔时间戳）与下一次 `nextRunAt`，再异步执行任务动作，避免应用重启或重复 `tick()` 导致同一槽位重复执行。
- **准点宽限与补执行（`MisfirePolicy`）**：
  - 超过计划时间 `onTimeGraceSeconds`（120 秒）内视为 `.scheduled` 准点触发。
  - 若因电脑休眠或应用关闭错过触发时间：`.runIfMissedToday` 在同一自然日内（且 `.workdays` 任务当天仍为工作日）触发 `.misfireCatchUp` 补执行一次；`.skip` 则直接推进到下一次计划时间。
- **中断恢复**：应用启动初始化 `TaskSchedulerStore` 时，会将上次异常退出遗留的 `.running` 执行记录自动修正为 `.failed`。
- **唤醒检测**：除 15 秒周期定时器外，调度器还监听 `NSWorkspace.didWakeNotification`，系统从睡眠唤醒后立即检查一次到期任务。

## 动作扩展与内置动作

各业务插件可在 `start(context:)` 中通过 `context.scheduler.register(action:)` 注册 `ScheduledTaskAction`（含 `parameterSpecs` 参数表单定义），并通过 `seedDefaultTaskIfNeeded(_:seedID:)` 首次写入默认任务（写入 `scheduler.seededIDs` 后即使被用户删除也不会自动复活）。

`TaskScheduler` 自带三个通用核心动作：

- **`core.reminder`（定时桌面提醒）**：到点按任务通知样式弹出自定义标题与内容的桌面提醒。
- **`core.clockOutReminder`（下班打卡提醒）**：到点弹出常驻桌面的下班打卡提醒卡片（`isPersistent = true`），若未填写自定义内容则自动拼接今日实际下班时间与剩余分钟；勾选「常驻不消失」（`keepVisible`）时，即使任务配置为系统通知也会通过 `resolveClockOutStyle` 自动转为 `.cornerCard` 浮动卡片；提供「已打卡」确认按钮与「N 分钟后再提醒」稍后重试定时器（`snoozeTimers`，关闭任务或退出调度器时自动清理）。
- **`core.shell`（执行终端命令）**：通过 `/bin/zsh -lc` 在登录 shell 环境下执行本地命令或脚本，支持自定义工作目录与超时时间，并记录退出码与输出摘要。

## 执行通知策略（`TaskNotifyPolicy`）

- `.onSuccessAndFailure`：成功或失败时通过 `ReminderCenter` 弹出提醒，跳过（如"今日已提交而跳过"）静默记录不打扰；若动作返回 `shouldNotifyOverride = true`（如当日无任何 Git 提交），仍会弹窗提醒用户手动处理。
- `.onFailureOnly`：仅失败时提醒。
- `.always`：无论成功、跳过或失败都提醒。
- `.never`：仅写数据库执行记录，不弹窗。
