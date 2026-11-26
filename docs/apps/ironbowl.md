# 饭碗主工作台应用（`Apps/IronBowl`）

`IronBowl`（Bundle ID：`com.taopaox.ironbowl`，产品名 `IronBowl`，显示名「饭碗」）是集成所有功能插件的 macOS 菜单栏常驻工作台应用。

## 源文件结构

| 文件 | 核心类型 | 职责 |
| :--- | :--- | :--- |
| `IronBowlApp.swift` | `IronBowlApp`, `AppDelegate` | 声明主窗口、`设置` 窗口、主菜单栏及独立万年历菜单栏 Scene；关闭主窗口时不退出应用 |
| `AppModel.swift` | `AppModel`, `AppKeys`, `DockMode` | 持有共享服务（DB/Settings/WorkCalendar/AI/Chat/Web/Reminders/SystemMonitor）、管理插件启停、Dock 策略与开机自启 |
| `MainView.swift` | `MainView`, `Sidebar`, `ResourceCard`, `ResourceDetailPopover`, `TodayCard` | 可收起左侧栏 + 右侧内容区，展示版本号徽标、未分组插件与目录子项、插件分组（如「汇报」包含日报、周报、月报）、固定网页、系统/饭碗 CPU 与内存占用卡片（含逐进程明细弹层）及下班倒计时 |
| `HomeView.swift` | `HomeView` | 首页「今天」T3 Code 风格工作台：顶栏（目录与读写/只读权限切换、详略选择器、插入卡片）、欢迎卡片网格（含一键对话生成日报/周报/月报快捷胶囊）与底部多模式输入器（支持双选择 AI 提供商与模型、按对话记忆模型，或切到「记日志」） |
| `HomeChatSidebar.swift` | `HomeChatSidebar` | 「今天」页内可折叠多对话列表栏（搜索、置顶、按天分组、运行状态、重命名、Finder 打开目录、删除） |
| `HomeChatTimeline.swift` | `HomeChatTimeline` | 对话时间线、基于 `DSMarkdownView` 的完整 Markdown 渲染、实时功能卡片与失败重试 |
| `HomeChatActivityView.swift` | `HomeChatActivityView` | 可折叠命令/工具/思考/文件改动输出详情、退出码与原始 JSONL 事件查看器 |
| `HomeChatCards.swift` | `HomeCardCatalog`, `HomeChatCardStrip`, `HomeCardPickerPopover` | 汇总核心卡片与已启用插件 `homeCards`，支持通过 `makeInteractiveChatCard(for:)` 在对话内渲染可操作活卡片与卡片选择器 |
| `MenuBar.swift` | `MenuBarLabel`, `MenuPanel` | 菜单栏图标与可自定义拼接文案，以及点击弹出的快捷面板（顶部展示当前版本） |
| `SettingsView.swift` | `SettingsView` 及各核心设置页 | 左侧搜索、分组导航与底部版本号，右侧各核心设置页（通用设置底部含「关于」版本信息与复制按钮） |

## 窗口与运行形态

- **`LSUIElement = true`**：默认作为菜单栏应用运行。
- **三种程序坞策略（`DockMode`）**：
  - `.whenWindowOpen`（默认）：主窗口打开时切为 `.regular` 显示在程序坞，关闭后切回 `.accessory` 仅留菜单栏。
  - `.always`：始终在程序坞显示。
  - `.never`：从不在程序坞显示。
- **菜单栏组合**：
  - 主菜单栏图标 `🍚` 后可按用户自定义顺序拼接任意插件 `MenuBarItem`（见 `app.menuBarItems`）。
  - 启用 `CalendarPlugin` 时，可额外在系统菜单栏显示独立的天气/日期/农历/时间图标与月历弹出面板（由 `app.calendarMenuShown` 控制）。
  - 两个状态栏 `MenuBarExtra(.window)` 面板均挂载了 `.menuBarPopoverDismissable()`：在 `MenuPanel` 点击「今天」、各插件入口、「设置」或「退出饭碗」，以及在万年历弹层点击离开弹层的操作后，会立即收起弹出面板。
- **主窗口关闭清理**：`AppModel.mainWindow(isOpen: false)` 会调用 `webSessions.detachAllDisplays()`，将可见网页标记为后台以允许按墓碑策略回收内存。
- **侧栏资源监控**：左下角 `ResourceCard` 位于「今天上班」卡片上方，展示 CPU 与内存占用，支持在「系统」（整机）与「饭碗」（自身主进程、子进程及活跃 `WKWebView` 渲染进程）间切换；切至「饭碗」时会在卡内直接展示 Top 3 占用项，点击可打开 `ResourceDetailPopover` 查看逐进程内存/CPU 明细、按内存或 CPU 排序，并一键休眠后台网页释放内存；采样仅在侧栏可见时通过 `.task` 定时执行（收起或关窗自动停止）。
- **侧栏下班倒计时卡片（`TodayCard`）**：依据 `WorkCalendar.onWorkTimeText(on:)`、`offWorkTimeText(on:)` 与 `effectiveWorkEnd(on:)` 展示今日上班时间（有打卡时显示实际打卡时间，否则显示配置上班时间）、实际下班时间以及 `距下班 X小时Y分` 剩余时长与进度条；有打卡记录时右上角显示「已打卡」，设置当日加班后右上角切换为紫色「加班 +Xh」、下班时间同步顺延，进度条亦切为紫色；休息日设置加班时显示「加班 +Xh」与「辛苦加班」。
- **版本展示**：通过 `IronBowlKit` 的 `AppVersionInfo` 与 `Bundle` 扩展（`displayVersion` / `fullVersion`）在侧栏顶部「饭碗」旁、菜单栏面板顶部、设置窗口左侧栏底部以及「通用 → 关于」卡片中展示当前版本号（支持一键复制）。
