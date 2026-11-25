# 定时任务插件（`SchedulerPlugin`）

`SchedulerPlugin`（`Packages/SchedulerPlugin`）为工作台提供独立的「定时任务」侧边栏管理页面、首页概览卡片、菜单栏倒计时项，并负责在主工作台启动和停止共享的 `TaskScheduler` 调度引擎。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `SchedulerPlugin.swift` | `SchedulerPlugin` | 插件入口（`id = "scheduler"`），启动/停止 `context.scheduler`，提供首页指标卡与菜单栏倒计时 |
| `Views/SchedulerView.swift` | `SchedulerView` | 定时任务主视图，支持「任务列表」与「执行记录」切换、指标概览、启停开关、立即运行与详情展开 |
| `Views/TaskEditorSheet.swift` | `TaskEditorSheet` | 新建/编辑定时任务弹窗，支持动作选择、执行周期、错过策略、动态动作参数与通知方式配置 |

## 主要功能

1. **任务列表管理**：
   - 展示已启用任务数、下一次计划执行时间与今日执行统计（成功/跳过/失败）。
   - 每条任务支持「立即运行」手动试跑、编辑配置、删除（带确认）及独立启停开关。
   - 若某任务绑定的业务插件被停用，页面会高亮「对应插件未启用」提示并引导前往「设置 → 通用」。
2. **动态动作表单（`ScheduledActionParameterSpec`）**：
   - 根据选中动作（如 `zentao.autoSubmitLog`、`core.reminder`、`core.shell`）自动渲染开关、下拉选择器、单行/多行文本输入框与步进器。
3. **执行记录审计**：
   - 支持按状态（全部 / 成功 / 跳过 / 失败）与任务筛选，展示触发来源（定时触发 / 错过补执行 / 手动运行）、执行耗时、结果摘要与可展开/复制的完整详细日志。
4. **首页与菜单栏**：
   - 首页「今天」注入 `scheduler.next` 卡片，显示最近一次即将执行的定时任务与倒计时。
   - 菜单栏可勾选 `scheduler.next`（「离下次定时任务还有多久」）。
