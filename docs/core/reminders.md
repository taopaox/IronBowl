# 提醒中心（`ReminderCenter`）

[`ReminderCenter.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Reminders/ReminderCenter.swift) 与 [`ReminderHistoryStore.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Reminders/ReminderHistoryStore.swift) 为插件提供跨样式的桌面提醒能力与历史消息持久化，同一 `ReminderContent.id` 再次触发时会自动替换旧的桌面弹窗，同时每次触发的历史消息都会保留在本地数据库中供工作台「消息提醒」页面回看。

## 提醒样式（`ReminderStyle`）

| 样式 | 说明 | 行为特点 |
| :--- | :--- | :--- |
| `.system` | 系统通知 | 通过 `UNUserNotificationCenter` 发送原生通知（仅 `.app` 运行时生效），受系统通知权限和勿扰模式约束 |
| `.cornerCard` | 右上角浮动卡片 | 自绘无边框非激活 `NSPanel`（`.statusBar` 层级），定位在主屏幕 `visibleFrame` 右上角，**不点击操作按钮不消失**，勿扰模式下仍可弹出 |
| `.centerDialog` | 屏幕中央弹框 | 自绘居中 `NSPanel`（宽度 420pt），盖在所有工作区窗口之上，支持拖拽移动 |

## 交互机制

- `ReminderContent` 包含 `id`、`title`、`message`、`systemImage`、`source`（默认按 `ReminderSource.infer(fromReminderID:)` 推断）、可选跳转目标（`targetPluginID` / `targetSettingsPage`）、`recordInHistory`（默认 `true`，设置页预览可设为 `false`）以及多个 `ReminderAction`（其中 `isPrimary = true` 渲染为 `.dsPrimary` 黑底主按钮，其余渲染为 `.dsSecondary`）。
- 浮动面板（`ReminderPanelView`）遵循 `DS.card` 与 `DS.border` 规范，点任意按钮先 `dismiss(id:)`、标记历史记录已处理，再执行对应 `action.handler()`。
- 系统通知模式下，将各按钮注册为 `UNNotificationCategory` 操作；点击通知本体等价于触发 `isPrimary` 主按钮，并自动将对应历史记录标为已读/已操作。`dismiss(id:)` 会同步清理待投递与已投递的同 `id` 系统通知。

## 历史消息持久化与状态管理

- **`ReminderSource`**：按来源区分提醒（`.zentao` 禅道日志 / `.scheduler` 定时任务 / `.attendance` 考勤同步 / `.general` 系统提醒）。
- **`ReminderDeliveryStatus`**：记录投递状态（`.delivered` / `.unavailable` / `.permissionDenied` / `.alertsDisabled` / `.failed`）与详细原因 `deliveryDetail`，当系统通知未授权或横幅关闭时仍可在历史列表查看原因。
- **`ReminderHistoryStore`**：基于 SQLite `reminderHistory` 表（迁移 `core.v7`，最多保留最近 500 条）提供 `insert`、`updateDelivery`、`markHandled`、`setRead`、`markAllRead`、`delete`、`clearAll`、`fetchRecent` 与 `prune`。
- **`ReminderCenter`**：使用 `@Observable` 暴露 `history: [ReminderHistoryRecord]` 与 `unreadCount: Int`，通过 `ReminderCenter(database:)` 在启动时自动加载历史记录，并对外提供 `reloadHistory()`、`setRead(id:isRead:)`、`markAllRead(source:)`、`markHandled(id:actionTitle:)`、`deleteHistory(id:)` 与 `clearHistory(source:)`；`ReminderCenter()` 无参初始化仍保持兼容（仅在内存记录）。

## 系统通知权限检测与设置快捷跳转

- **`SystemNotificationStatus`**：归纳当前系统通知可用状态，包括 `.unavailable`（非 `.app` 环境）、`.notDetermined`（未授权）、`.denied`（未允许通知）、`.alertsDisabled`（权限已允许但提醒样式为「无」或 `alertSetting == .disabled`）与 `.authorized`（`canPresentAlert == true`）。纯函数 `SystemNotificationStatus.evaluate(authorizationStatus:alertSetting:alertStyle:)` 负责将 `UNNotificationSettings` 映射为上述状态。
- **`ReminderDeliveryResult`**：`showAndReport(_:style:)` 返回异步投递结果（`.delivered` / `.unavailable` / `.permissionDenied` / `.alertsDisabled` / `.failed(String)`），供设置页预览等需要明确反馈的场景判断通知是否成功发出。
- **状态查询与授权**：`systemNotificationStatus()` 读取当前通知配置，`requestSystemNotificationAuthorization()` 在 `.notDetermined` 时向系统发起授权弹窗并返回最新状态。
- **快捷跳转系统设置**：`ReminderCenter.systemNotificationSettingsURLs(bundleIdentifier:)` 生成以 `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundleID>` 为首项、系统通知面板及旧版通知面板为兜底的候选 URL，`ReminderCenter.openSystemNotificationSettings()` 依次尝试通过 `NSWorkspace.shared.open` 打开。
