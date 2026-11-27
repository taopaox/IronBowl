# 独立版万年历应用（`Apps/Calendar`）

`IronBowlCalendar`（Bundle ID：`com.taopaox.ironbowl.calendar`，包名 `IronBowlCalendar.app`，`Info.plist` 保留与包名一致的英文 `CFBundleName`/`CFBundleDisplayName` 以符合 macOS 本地化校验规则，并开启 `LSHasLocalizedDisplayName = true` 配合 `Apps/Calendar/{zh-Hans,en}.lproj/InfoPlist.strings` 在访达、程序坞、系统菜单栏及登录项中统一显示为「万年历」）是一个轻量化独立 macOS 应用，仅依赖 `IronBowlKit` 和 `CalendarPlugin`，适合只想单独使用菜单栏万年历与天气的场景。

## 核心特点

- **共享应用源码**：除 [`CalendarApp.swift`](../../Apps/Calendar/CalendarApp.swift)（`CalendarApp`、`CalendarAppDelegate`、`StandaloneCalendar`、`StandaloneSettings`）外，通过 [`Apps/Shared/AppUpdater.swift`](../../Apps/Shared/AppUpdater.swift) 与主工作台共享 Sparkle 2 自动更新封装。
- **与主工作台数据互通**：
  - 打开同一个数据库 `~/Library/Application Support/IronBowl/ironbowl.sqlite`。
  - 共享外观主题（`app.appearance`）、字体缩放（`app.fontScale`）、法定节假日缓存、手动放假/补班标记（`holidayOverride`）、系统/钉钉会议日程开关（`calendar.events.*`）、天气城市和源配置。
  - 由于独立版不依赖 `ZentaoLogPlugin`（`PluginContext.appendDailyLogDraft == nil`），日期详情卡与弹层会展示会议安排与入会入口，但不展示「+ 记日报」按钮。
  - 通过 `DistributedNotificationCenter` 与主应用实时同步设置与节假日更新。
  - 当独立版 `IronBowlCalendar` 与主工作台 `IronBowl` 同时运行时，`CalendarAppDelegate` 与 `CalendarModel` 会通过 `DistributedNotificationCenter` 广播启停生命周期与响应主工作台探针，配合主工作台的 `NSWorkspace.runningApplications` KVO 监听与 `StandaloneCalendarPresenceState`，确保无论先启动主工作台还是先启动独立版万年历，主工作台都会自动隐藏其内置状态栏日历，仅保留独立版这一份状态栏日历。
- **三个 SwiftUI Scene**：
  1. `MenuBarExtra`（`.window`）：顶部菜单栏支持 20 套可选状态栏视觉风格，显示可选万年历 Logo / 天气 / AQI / 日期 / 星期 / 农历 / 休班角标 / 时间，点开展示紧凑月历面板 `CalendarPopover`（独立版底栏展示版本号与「退出万年历」按钮），并挂载 `.menuBarPopoverDismissable()` 以便点击跳转大窗口、设置或退出时立即收起弹层。
  2. `Window("万年历", id: "calendar")`：大窗口月历 `CalendarMainView`（顶部标题旁展示当前版本号与 `DSSloganView(style: .inline)`）。
  3. `Window("万年历设置", id: "settings")`：设置窗口默认定位至「通用」页（`StandaloneGeneralSettings`，通过与主工作台共享的 `LaunchAtLoginController` 与 `DSLaunchAtLoginRow` 配置开机自动启动、支持 `requiresApproval` 系统登录项引导跳转及切回前台自动同步），并复用插件的「月历」「状态栏」「外观」「节假日」「天气」五个设置页，在「外观」页中通过 `StandaloneAppearanceSettings` 合并展示 `CalendarAppearanceSettings`（弹出面板样式）与 `DSAppearanceSettingsView`（应用主题与字体缩放）；同时在侧栏底部展示版本号与无框衬线品牌标语，并附带「关于」设置页展示 `AppLogo` 品牌图标（`Apps/Calendar/Assets.xcassets/AppLogo.imageset`，应用图标为满幅 `Apps/Calendar/Assets.xcassets/AppIcon.appiconset`）、品牌标语、复制完整版本信息以及 Sparkle 2 软件更新与自动检查/下载开关（`SUFeedURL` 指向 `appcast-calendar.xml`，配 `SUPublicEDKey` 公钥校验）。
- **系统菜单与更新入口**：通过 `.commands` 替换 `.appInfo`，点击「关于万年历」时以 `AppBrand.aboutCredits()` 展示品牌标语，并在菜单中提供「检查更新…」入口（调用 `StandaloneCalendar.updater`）。
