# 待办与备忘插件（`TodoPlugin`）

`TodoPlugin`（`Packages/TodoPlugin`）提供工作台待办与日程备忘管理，并与万年历日期格、禅道日报草稿及提醒中心全面联动。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `TodoPlugin.swift` | `TodoPlugin`, `TodoReminderSettings` | 插件入口、侧栏角标（逾期/今日计数）、菜单栏待办数、首页今日待办卡、20 秒定时提醒轮询与一键带入日报草稿 |
| `Views/TodoMainView.swift` | `TodoMainView`, `TodoItemRow` | 待办与备忘主页面：统计指标、快捷创建（日期/优先级/预估工时/定时提醒）、分组筛选、搜索、状态切换与转入禅道日报 |

## 跨模块联动能力

- **共享数据层（`IronBowlKit/Todo/TodoStore.swift`）**：数据持久化于核心表 `todoItem`（`core.v8`），通过 `DistributedNotificationCenter`（`com.taopaox.ironbowl.todosDidChange`）在主工作台与独立版万年历之间实时同步。
- **万年历联动（`CalendarPlugin`）**：月历格子右下角展示当日待办状态圆点（有未完成为品牌琥珀色，全部完成为绿色）；大窗口日期详情卡展示当日待办列表，支持直接勾选和就地新建。
- **禅道日报联动（`ZentaoLogPlugin`）**：日报手账左页展示当天相关待办（到期或当天完成），支持单条「+ 记入草稿」或「一键带入已完」，也支持在待办页点击「记入日报」通过 `ZentaoLogPlugin.appendExternalDraft` 写入待提交草稿并记录 `loggedDate`。
- **提醒中心联动**：为待办设置提醒时间后，到期自动按 `todo.reminderStyle`（默认右上角浮动卡片）弹出提醒，支持「15 分钟后」延后、「去查看」与「标为已完成」，并写入 `reminderHistory`（来源 `ReminderSource.todo`）。

## 设置键

- `todo.reminderStyle`：待办提醒样式（`system` / `cornerCard` / `centerDialog`，默认 `.cornerCard`）。
