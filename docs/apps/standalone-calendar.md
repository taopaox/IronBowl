# 独立版万年历应用（`Apps/Calendar`）

`IronBowlCalendar`（Bundle ID：`com.taopaox.ironbowl.calendar`，显示名「饭碗万年历」）是一个轻量化独立 macOS 应用，仅依赖 `IronBowlKit` 和 `CalendarPlugin`，适合只想单独使用菜单栏万年历与天气的场景。

## 核心特点

- **单一入口文件**：全部宿主代码集中在 [`CalendarApp.swift`](../../Apps/Calendar/CalendarApp.swift)（`CalendarApp`、`CalendarAppDelegate`、`StandaloneCalendar`、`StandaloneSettings`）。
- **与主工作台数据互通**：
  - 打开同一个数据库 `~/Library/Application Support/IronBowl/ironbowl.sqlite`。
  - 共享外观主题（`app.appearance`）、字体缩放（`app.fontScale`）、法定节假日缓存、手动放假/补班标记（`holidayOverride`）、天气城市和源配置。
  - 通过 `DistributedNotificationCenter` 与主应用实时同步设置与节假日更新。
- **三个 SwiftUI Scene**：
  1. `MenuBarExtra`（`.window`）：顶部菜单栏显示天气/日期/星期/农历/时间，点开展示紧凑月历面板 `CalendarPopover`（带「退出」按钮），并挂载 `.menuBarPopoverDismissable()` 以便点击跳转大窗口、设置或退出时立即收起弹层。
  2. `Window("饭碗万年历", id: "calendar")`：大窗口月历 `CalendarMainView`。
  3. `Window("万年历设置", id: "settings")`：精简设置窗口，直接复用插件的「月历」「状态栏」「外观」「节假日」「天气」五个设置页，并在「外观」页中通过 `StandaloneAppearanceSettings` 合并展示 `CalendarAppearanceSettings`（弹出面板样式）与 `DSAppearanceSettingsView`（应用主题与字体缩放）。
