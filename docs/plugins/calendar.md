# 万年历插件（`CalendarPlugin`）

`CalendarPlugin`（`Packages/CalendarPlugin`）同时服务于工作台主应用与独立版「饭碗万年历」，提供公历/农历对照、24 节气、节日、法定调休角标、天气预报与多主题菜单栏弹层。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `CalendarPlugin.swift` | `CalendarPlugin` | 暴露主视图、设置页（月历/状态栏/外观/节假日/天气）、菜单栏项（日期/农历/天气）、首页天气卡与快捷操作 |
| `CalendarModel.swift` | `CalendarModel`, `CalendarKeys`, `CalendarMenuBarPolicy`, `MenuBarDisplayConfig`, `MenuBarSegment`, `DayCell` | 42 格月历网格计算、整分钟/整秒动态时钟、菜单栏分段格式化、独立版万年历进程避让策略、天气刷新调度与倒计时文案 |
| `Lunar/Lunar.swift` | `Lunar`, `LunarDate` | 离线农历、干支纪年/生肖、Meeus 太阳视黄经 24 节气与公历/农历/按星期节日 |
| `Weather/Weather.swift` | `WeatherService`, `WeatherSource`, `WeatherSnapshot` | Open-Meteo（地理编码搜索城市 + 预报 + US AQI）与和风天气（预报 + AQI）数据抓取 |
| `Views/CalendarViews.swift` | `CalendarMainView` | 完整窗口月历界面 |
| `Views/CalendarSettings.swift` | `CalendarDisplaySettings`, `CalendarStatusBarSettings`, `CalendarAppearanceSettings`, `CalendarHolidaySettings`, `WeatherSettings` | 月历、状态栏日历（20 套风格卡片选择器、Logo/时间/日期/休班角标/天气开关与实时预览）、外观（弹出面板样式）、节假日（复用 `DSHolidaySettingsView`）与天气设置页 |
| `Views/CalendarMenuBarStyle.swift` | `CalendarMenuBarStyleCategory`, `CalendarMenuBarStyle`, `CalendarMenuBarSnapshot` | 5 大类共 20 套可选状态栏视觉风格定义与结构化实时渲染快照 |
| `Views/CalendarMenuBarRenderer.swift` | `CalendarAssets`, `CalendarMenuBarRenderer` | 状态栏 20 套风格 CoreGraphics 离线图像渲染器与内置 `Resources/CalendarLogo.png` 加载器 |
| `Views/CalendarPopover.swift` | `CalendarPopover`, `CalendarMenuBarLabel`, `CalendarMenuBarPreview` | 状态栏标签、设置预览标签与紧凑双栏弹出面板 |
| `Views/CalendarPopoverStyle.swift` | `CalendarPopoverStyle`, `CalendarPopoverPalette` | 6 套弹出面板主题（跟随系统、跟随外观、简约白、深邃黑、经典红、经典蓝） |

## 历法与天气能力

- **农历与节气**：农历基于系统 `Calendar(identifier: .chinese)`（按北京时间正午防跨日）；24 节气通过 Meeus 太阳视黄经迭代求解，完全离线可用。
- **状态栏渲染（20 套可选风格）**：`CalendarMenuBarLabel` 从 `CalendarModel.menuBarSnapshot` 与 `CalendarModel.menuBarStyle` 获取数据与当前风格，调用 `CalendarMenuBarRenderer` 离线绘制为高度 `22pt` 的 Retina `NSImage`，避免 macOS `MenuBarExtra` 动态文本插值在切换显示项时截断或消失；支持 5 大分类（极简原生、双行高密、徽章卡片、国风创意、仪表科技）共 20 套视觉风格（`#01` 双行微缩仪表卡～`#20` 呼吸大时钟）。默认「原生极简排印（`.nativeMinimal`）」在未开启全彩 Logo 且未显示休/班角标时输出模板图像（`isTemplate = true`），其余风格及含全彩元素场景输出非模板图像（`isTemplate = false`）并自适应系统浅/深色。`CalendarStatusBarSettings` 内置按分类筛选与深浅背景切换的 20 套风格卡片选择器与实时预览胶囊。
- **双进程状态栏自动避让**：`CalendarMenuBarPolicy` 监听独立版 `com.taopaox.ironbowl.calendar` 进程启停，当独立版「饭碗万年历」正在运行时，主工作台通过 `CalendarModel.shouldShowEmbeddedMenuBar` 自动隐藏内置状态栏日历（保留 `calendar.menuBar.enabled` 设置值不覆盖），并在 `CalendarStatusBarSettings` 展示提示横幅，独立版退出后自动恢复。
- **休/班标识与倒计时**：直接读取共享 `WorkCalendar` 数据，显示「休」「班」角标，并支持百度风格倒计时（今天显示距下一个法定节假日天数）。
- **弹出面板交互与主题**：
  - 在 `CalendarPopover` 中点击会离开弹层的操作（城市/天气设置、打开大窗口、日历设置、退出万年历）时，会通过 `\.dismissMenuBarPopover` 立即收起弹出面板；面板内月历浏览（年/月下拉切换、前后翻月、返回今天、选日期）与弹出样式实时预览（`PopoverStyleDropdown`）则保留弹层打开。
  - 支持 6 套样式——「跟随系统」（直接随 macOS 系统深浅模式切换，不受主应用强制外观影响）、「跟随外观」（随共享设置 `app.appearance` 切换）以及「简约白」「深邃黑」「经典红」「经典蓝」固定 sRGB 配色。
- **天气与空气质量数据源**：默认使用免注册的 Open-Meteo（并发抓取 `air-quality-api.open-meteo.com/v1/air-quality` 的 `us_aqi`）；支持切换为和风天气（并发抓取 `/airquality/v1/current/{lat}/{lon}` 并在失败时降级 `/v7/air/now`），并缓存上次天气快照 `weather.last` 以保证断网可用。

## 设置键（`CalendarKeys`）

- `calendar.firstWeekday`（默认 `2` 周一）、`calendar.popover.style`（默认 `.appearance`）
- `calendar.menuBar.enabled`（默认 `true`）、`calendar.menuBar.style`（默认 `.nativeMinimal`，可选 20 套 `CalendarMenuBarStyle`）、`calendar.menuBar.logo`（默认 `false`）
- 时间选项：`calendar.menuBar.time`（默认 `true`）、`calendar.menuBar.time.icon`（默认 `false`）、`calendar.menuBar.time.24hour`（默认 `true`，在「月历」和「状态栏 → 时间选项」均可通过「时间制式（24 小时制 / 12 小时制）」切换，并同步作用于状态栏时间、弹出面板右侧大时钟与主窗口天气更新时间）、`calendar.menuBar.time.period`（默认 `false`）、`calendar.menuBar.time.seconds`（默认 `false`）
- 日期选项：`calendar.menuBar.dateSection`（默认 `true`）、`calendar.menuBar.lunar`（默认 `false`）、`calendar.menuBar.date`（默认 `true`）、`calendar.menuBar.weekday`（默认 `true`）、`calendar.menuBar.holidayBadge`（默认 `true`）
- 天气选项：`calendar.menuBar.weatherSection`（默认 `true`）、`calendar.menuBar.weather`（默认 `true`）、`calendar.menuBar.aqi`（默认 `false`）
- `weather.source`、`weather.city`、`weather.qweatherKey`、`weather.qweatherHost`、`weather.refreshMinutes`（默认 `30`）、`weather.last`
