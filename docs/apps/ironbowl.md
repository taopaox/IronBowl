# 饭碗主工作台应用（`Apps/IronBowl`）

`IronBowl`（Bundle ID：`com.taopaox.ironbowl`，包名 `IronBowl.app`，`Info.plist` 保留与包名一致的英文 `CFBundleName`/`CFBundleDisplayName` 以符合 macOS 本地化校验规则，并开启 `LSHasLocalizedDisplayName = true` 配合 `Apps/IronBowl/{zh-Hans,en}.lproj/InfoPlist.strings` 在访达、程序坞、系统菜单栏及登录项中统一显示为「饭碗」）是集成所有功能插件的 macOS 菜单栏常驻工作台应用。

## 源文件结构

| 文件 | 核心类型 | 职责 |
| :--- | :--- | :--- |
| `IronBowlApp.swift` | `IronBowlApp`, `AppDelegate` | 声明主窗口、`设置` 窗口、主菜单栏及独立万年历菜单栏 Scene，并在应用菜单提供「检查更新…」入口；关闭主窗口时不退出应用 |
| `AppModel.swift` | `AppModel`, `AppKeys`, `DockMode` | 持有共享服务（DB/Settings/UserProfile/WorkCalendar/AI/Chat/Web/Reminders/SystemMonitor/Updater/LaunchAtLoginController，含核心页面 `homeID`/`remindersID`）、管理插件启停、网页会话关闭调度（`closeWebSession(id:)`）与 Dock 策略 |
| `Apps/Shared/AppUpdater.swift` | `AppUpdater`, `AppUpdateSettingsRows` | 封装 Sparkle 2（`SPUStandardUpdaterController`）初始化、KVO 状态同步、置前激活及设置页更新开关行（双应用共享） |
| `MainView.swift` | `MainView`, `Sidebar`, `SidebarWebPluginRow`, `ResourceCard`, `ResourceDetailPopover`, `TodayCard` | 可平滑滑动收起/展开的左侧栏（顶部切换按钮随侧栏收放同步滑移、包含「今天」「消息提醒」（带未读角标）、未分组插件与目录子项、插件分组、固定网页、资源监控卡片、下班倒计时及左下角个人资料入口）+ 右侧内容区 |
| `UserProfileEditor.swift` | `UserProfileAvatarView`, `UserProfileAvatarPicker`, `UserProfileEditorSheet` | 左下角个人资料头像视图、本地图片选择器与点击头像/姓名弹出的资料编辑弹窗（自定义头像/Logo、显示姓名与个人标语） |
| `RemindersView.swift` | `RemindersView`, `ReminderHistoryCard` | 左侧「消息提醒」历史消息中心：展示未读/今日/最近统计指标、全部/未读/已读标签、来源筛选与搜索、按天分组卡片、投递状态与操作记录标记、一键已读、删除清空及快捷跳转关联插件或设置页 |
| `HomeView.swift` | `HomeView` | 首页「今天」T3 Code 风格工作台：顶栏（目录与读写/只读权限切换、详略选择器、插入卡片）、欢迎卡片网格（含一键对话生成日报/周报/月报快捷胶囊）与底部多模式输入器（支持双选择 AI 提供商与模型、按对话记忆模型，或切到「记日志」） |
| `HomeChatSidebar.swift` | `HomeChatSidebar` | 「今天」页内可平滑滑动收起/展开的多对话列表栏（搜索、置顶、按天分组、运行状态、重命名、Finder 打开目录、删除） |
| `HomeChatTimeline.swift` | `HomeChatTimeline` | 对话时间线、基于 `DSMarkdownView` 的完整 Markdown 渲染、实时功能卡片与失败重试 |
| `HomeChatActivityView.swift` | `HomeChatActivityView` | 可折叠命令/工具/思考/文件改动输出详情、退出码与原始 JSONL 事件查看器 |
| `HomeChatCards.swift` | `HomeCardCatalog`, `HomeChatCardStrip`, `HomeCardPickerPopover` | 汇总核心卡片与已启用插件 `homeCards`，支持通过 `makeInteractiveChatCard(for:)` 在对话内渲染可操作活卡片与卡片选择器 |
| `MenuBar.swift` | `MenuBarLabel`, `MenuPanel`, `MenuWorkHeroCard`, `MenuOvertimeQuickBar`, `MenuStatusCard`, `MenuShortcutTile` | 菜单栏透明底双行微缩仪表卡标签（调用 `MenuBarCardRenderer` 并传入 `MenuBarIcon` 插画图标），以及点击弹出的分层卡片式快捷面板（`AppLogo` 品牌图标与日期栏、今日上下班主卡及底部 `MenuOvertimeQuickBar` 快捷加班修改条、概览状态卡片网格与含「今天」「消息提醒」及各启用插件的快捷入口瓷砖，底栏提供「设置」「检查更新」「退出饭碗」） |
| `SettingsView.swift` | `SettingsView` 及各核心设置页 | 左侧搜索、分组导航与底部版本号，右侧各核心设置页（「通用 → 个人资料」配置左下角自定义头像/Logo、显示姓名与个人标语，「通用 → 启动与显示」通过共享 `DSLaunchAtLoginRow` 配置开机自动启动并在需要系统授权时提供引导跳转，独立的「关于」页 `AboutSettings` 展示 `AppLogo` 品牌图标、版本信息、复制按钮及 Sparkle 2 软件更新与自动检查/下载开关） |

## 窗口与运行形态

- **`LSUIElement = true`**：默认作为菜单栏应用运行。
- **三种程序坞策略（`DockMode`）**：
  - `.whenWindowOpen`（默认）：主窗口打开时切为 `.regular` 显示在程序坞，关闭后切回 `.accessory` 仅留菜单栏。
  - `.always`：始终在程序坞显示。
  - `.never`：从不在程序坞显示。
- **菜单栏组合**：
  - 主菜单栏采用 `IronBowlKit` 的 `MenuBarCardRenderer` 将透明底饭碗插画图标 `MenuBarIcon`（`Apps/IronBowl/Assets.xcassets/MenuBarIcon.imageset`）与用户自定义顺序拼接的 `MenuBarItem`（见 `app.menuBarItems`）离线绘制为 `22pt` 透明底全彩非模板 `NSImage`「双行微缩仪表卡」（无深色背景框，文字与分隔线随系统浅/深色自适应对比度）：`core.offwork`、提醒与定时任务以双行堆叠展示（上行显示 `距下班 · XX%` / 加班紫色 `加班 · XX%`，下行显示中文紧凑倒计时），其余状态以竖线分隔语义色展示；「设置 → 通用 → 菜单栏显示」同步提供实时微卡预览。
  - 点击主菜单栏图标弹出的 `MenuPanel` 采用灰底白卡分层布局（`DS.groupBackground` + `DS.card`）：顶部展示 `AppLogo` 品牌图标、品牌名、版本胶囊、日期/农历/节假日标签与「工作台」快捷按钮；中部展示今日上下班主卡（`MenuWorkHeroCard`，上部点击打开工作台，展示倒计时、进度条、加班/打卡状态与上下班时间；底部内置 `MenuOvertimeQuickBar` 快捷调整今日加班时长，提供 `+1h`~`+4h` 预设切换、`±0.5h` 微调与一键清除，修改时保持弹层展开并实时刷新倒计时、下班时间、进度条及状态栏微卡）以及最多 4 张已启用插件概览卡片（`MenuStatusCard` 2 列网格）；下方展示「今天」与各已启用插件的快捷入口瓷砖卡（`MenuShortcutTile`，带 `sidebarBadge` 状态圆点），底部提供「设置」与「退出饭碗」。
  - 启用 `CalendarPlugin` 时，可额外在系统菜单栏显示独立的天气/日期/农历/时间图标与月历弹出面板（由 `app.calendarMenuShown` 只读计算属性驱动 `MenuBarExtra(isInserted:)`，避免 SwiftUI 状态回写覆盖设置）；通过 `NSWorkspace.runningApplications` KVO、`DistributedNotificationCenter` 生命周期握手及定时核验，无论先开饭碗还是先开独立版 `IronBowlCalendar`（`com.taopaox.ironbowl.calendar`），主工作台都能自动隐藏内置状态栏日历以避免顶部状态栏出现两个时间组件，且不修改用户的 `calendar.menuBar.enabled` 配置，独立版退出后自动恢复。
  - 两个状态栏 `MenuBarExtra(.window)` 面板均挂载了 `.menuBarPopoverDismissable()`：在 `MenuPanel` 点击「今天」、各插件入口、「设置」或「退出饭碗」，以及在万年历弹层点击离开弹层的操作后，会立即收起弹出面板。
- **主窗口关闭清理**：`AppModel.mainWindow(isOpen: false)` 会调用 `webSessions.detachAllDisplays()`，将可见网页标记为后台以允许按墓碑策略回收内存。
- **侧栏资源监控**：左下角 `ResourceCard` 位于「今天上班」卡片上方，展示 CPU 与内存占用，支持在「系统」（整机）与「饭碗」（自身主进程、子进程及活跃 `WKWebView` 渲染进程）间切换；切至「饭碗」时会在卡内直接展示 Top 3 占用项，点击可打开 `ResourceDetailPopover` 查看逐进程内存/CPU 明细、按内存或 CPU 排序，并一键休眠后台网页或直接关闭网页进程释放内存；采样通过 `.task(id: isVisible)` 在侧栏展开可见时定时执行（收起侧栏或关窗自动停止，展开时恢复）。
- **侧栏已打开网页管理**：侧栏中的固定网页（`PinnedSidebarRow`）与打开了主页的网页插件行（`SidebarWebPluginRow`）在运行中显示绿色状态圆点、休眠时显示 `moon.zzz`，悬停或右键菜单提供「关闭网页」按钮以随时销毁会话释放内存。
- **侧栏下班倒计时卡片（`TodayCard`）**：依据 `WorkCalendar.onWorkTimeText(on:)`、`offWorkTimeText(on:)` 与 `effectiveWorkEnd(on:)` 展示今日上班时间（有打卡时显示实际打卡时间，否则显示配置上班时间）、实际下班时间以及 `距下班 X小时Y分` 剩余时长与进度条；有打卡记录时右上角显示「已打卡」，设置当日加班后右上角切换为紫色「加班 +Xh」、下班时间同步顺延，进度条亦切为紫色；休息日设置加班时显示「加班 +Xh」与「辛苦加班」。
- **左下角个人资料（`UserProfileStore` / `UserProfileEditorSheet`）**：左侧栏底栏支持自定义显示姓名（留空时回退系统 `NSFullUserName()` 或「我」）、个人标语（非空时展示在姓名下方，不影响顶部官方品牌标语）以及自定义头像/Logo（本地图片经归一化为 PNG 存于 `~/Library/Application Support/IronBowl/user-avatars/`，未设置时显示默认 `AppLogo`）；点击左下角个人资料区可直接弹出编辑弹窗，也可在「设置 → 通用 → 个人资料」中修改或恢复默认。
- **版本展示与自动更新**：通过 `IronBowlKit` 的 `AppVersionInfo` 与 `Bundle` 扩展（`displayVersion` / `fullVersion`）在侧栏顶部「饭碗」旁、菜单栏面板顶部、设置窗口左侧栏底部以及「关于」设置页中展示当前版本号（支持一键复制）；并通过 `AppUpdater` 接入 Sparkle 2（`SUFeedURL` 指向 `appcast-ironbowl.xml`，配 `SUPublicEDKey` Ed25519 公钥校验），在应用菜单「检查更新…」、菜单栏面板底栏「检查更新」与「设置 → 关于」提供手动检查及自动检查/自动下载开关。
- **全局品牌标语**：通过 `AppBrand.slogan`（及窄栏双行版 `AppBrand.twoLineSlogan`）与无框衬线 `DSSloganView` 在主窗口左侧栏顶部、首页「今天」欢迎区主标题下方与对话输入区底部、菜单栏快捷面板顶部、收起侧栏时的万年历页头、手账（日报/周报/月报）桌面底部落款与未配置/即将推出页面、设置窗口左侧栏底部、「关于」设置页品牌卡以及 macOS 原生「关于饭碗」面板中统一醒目展示「先把饭碗端稳，再慢慢加菜，不烧心。」。
