# 定时任务插件（`SchedulerPlugin`）

`SchedulerPlugin`（`Packages/SchedulerPlugin`）为工作台提供独立的「定时任务」侧边栏管理页面、首页概览卡片、菜单栏倒计时项，并负责在主工作台启动和停止共享的 `TaskScheduler` 调度引擎。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `SchedulerPlugin.swift` | `SchedulerPlugin` | 插件入口（`id = "scheduler"`），启动/停止 `context.scheduler`，提供首页指标卡与菜单栏倒计时 |
| `Views/SchedulerView.swift` | `SchedulerView` | 定时任务主视图，支持「任务列表」与「执行记录」切换、指标概览、启停开关、立即运行与详情展开 |
| `Views/TaskEditorSheet.swift` | `TaskEditorSheet` | 新建/编辑定时任务弹窗，支持动作选择、执行周期、错过策略、动态动作参数与通知方式配置 |

## 主要功能

1. **内置默认任务「打卡提醒」**：
   - 首次启动通过 `seedDefaultTaskIfNeeded`（`seedID = "builtin.core.clockOutReminder"`）自动写入并启用「打卡提醒」任务，绑定 `core.clockOutReminder` 动作，采用 `.beforeWorkEnd`（工作日下班前 5 分钟）周期与 `.cornerCard`（常驻不消失）提醒方式；若用户手动删除不会自动重建。
2. **任务列表管理**：
   - 展示已启用任务数、下一次计划执行时间与今日执行统计（成功/跳过/失败）。
   - 每条任务支持「立即运行」手动试跑、编辑配置、删除（带确认）及独立启停开关；开启常驻不消失的打卡提醒任务会显示「常驻不消失」标签。
   - 若某任务绑定的业务插件被停用，页面会高亮「对应插件未启用」提示并引导前往「设置 → 通用」。
3. **动态动作表单与下班前预览**：
   - 在 `TaskEditorSheet` 中根据选中动作（如 `zentao.autoSubmitLog`、`core.clockOutReminder`、`core.reminder`、`core.shell`）自动渲染开关、下拉选择器、单行/多行文本输入框与步进器。
   - 周期选择「下班前（工作日）」时提供提前分钟数步进器与今日实际下班参考触发时间预览；内置提醒类动作自动隐藏冗余的通知时机选项。
4. **执行记录审计**：
   - 支持按状态（全部 / 成功 / 跳过 / 失败）与任务筛选，展示触发来源（定时触发 / 错过补执行 / 手动运行）、执行耗时、结果摘要与可展开/复制的完整详细日志。
5. **首页与菜单栏**：
   - 首页「今天」注入 `scheduler.next` 卡片，显示最近一次即将执行的定时任务与倒计时。
   - 菜单栏可勾选 `scheduler.next`（「离下次定时任务还有多久」）。
