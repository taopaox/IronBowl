# 视觉规范与设计系统

IronBowl 的 UI 规范集中在 [`DesignSystem.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/DesignSystem.swift)、[`SharedSettings.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/SharedSettings.swift)、[`WindowTitleBar.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/WindowTitleBar.swift) 与 [`MenuBarPopoverDismiss.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/MenuBarPopoverDismiss.swift)。界面风格参照 WorkBuddy：浅灰侧栏、纯白内容区、1px 细边框白卡、高对比黑色主按钮与大留白，并随系统日间/夜间模式自动切换。

## 颜色令牌（`DS`）

新增或修改界面应优先复用 `DS` 语义令牌，避免硬编码静态 RGB 色值：

| 令牌 | 浅色值 | 深色值 | 适用场景 |
| :--- | :--- | :--- | :--- |
| `DS.sidebar` | `#F7F7F8` | `#1C1C1E` | 主窗口与设置窗口左侧栏底色 |
| `DS.canvas` | `#FFFFFF` | `#141416` | 内容区与菜单栏面板主背景 |
| `DS.groupBackground` | `#F5F5F7` | `#141416` | 设置页灰底白卡的外层背景 |
| `DS.card` | `#FFFFFF` | `#222225` | 卡片、输入控件与按钮背景 |
| `DS.well` | `#F4F4F5` | `#232326` | 无边框浅灰指标块、菜单栏统计区 |
| `DS.border` / `DS.borderStrong` | 黑 `6%` / `10%` | 白 `9%` / `15%` | 卡片细边框、分隔线与控件描边 |
| `DS.hover` / `DS.selected` | 黑 `4%` / `6.5%` | 白 `6%` / `10%` | 列表悬停与选中态 |
| `DS.pickerSelected` | `#F4F4F5` | 白 `10%` | 下拉浮层选项选中行背景 |
| `DS.primaryFill` / `DS.onPrimary` | `#18181B` / `#FFFFFF` | `#F4F4F5` / `#18181B` | 主按钮背景与前景文字 |
| `DS.toggle` | `#16B38A` | `#1FC79B` | 开关激活色、主题卡片选中框 |
| `DS.brand` | `#F59E24` | `#FFB840` | 品牌强调色（进度条、草稿状态） |
| `DS.danger` / `DS.warning` / `DS.success` | `#DC3B3B` / `#B76E00` / `#13875F` | `#F07070` / `#F5B54A` / `#3DD39A` | 错误、警告（兜底/休息日）、成功（已记录） |

## 字体与全局缩放

- **缩放档位**（`AppSharedKeys.fontScales`）：`[0.9, 1.0, 1.1, 1.2, 1.3, 1.4]`，对应设置页滑块「小 · 默认 · 大」。
- **使用方式**：
  - 文本统一通过 `DS.font(_ size: CGFloat, _ weight: Font.Weight)`、`DS.mono(_ size: CGFloat)` 或预设样式（`DS.heroTitle`、`DS.pageTitle`、`DS.sectionTitle`、`DS.rowTitle`、`DS.body`、`DS.caption`）获取字号。
  - 控件宽高通过 `DS.s(_ v: CGFloat)` 等比取整缩放。
  - 宿主根视图绑定 `.id(app.fontScale)`，在滑块松手变更 `DS.fontScale` 后触发全局视图重建刷新（见 `WebHostRepresentable.dismantleNSView` 对重建时 `WKWebView` 的保护）。

## 核心组件库（`DS*`）

| 组件 | 说明 |
| :--- | :--- |
| `DSPageHeader` | 页面顶栏（左标题 + 自定义前置视图 + 右侧操作区），内置 `.windowTitleBar()` |
| `DSCard` | `12pt` 圆角白卡，支持 `padding` 与 `dashed: true` 虚线添加卡 |
| `DSMetric` | 无边框浅灰指标卡（小标签 + 大号等宽数字 + 副说明） |
| `DSBanner` | 提示横幅，支持 `.info` / `.success` / `.warning` / `.danger` 与文本可选中 |
| `DSSection` / `DSRow` / `DSBlockRow` | 设置页分组容器，自动在相邻行间绘制内缩 `Divider` |
| `DSToggle` / `DSPicker` / `DSStepper` / `DSTabs` | 绿色开关、浮层卡片下拉选择器（[`DSPicker.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/DSPicker.swift)，支持 `DSPickerOption` 副标题与绿色选中对勾）、数字步进器、分段标签 |
| `DSSidebarItem` / `DSSidebarSection` | 侧边栏条目（支持 `badgeColor` 语义状态角标）与分区小标题 |
| `DSPrimaryButtonStyle` 等 | `.dsPrimary`、`.dsSecondary`、`.dsGhost`、`.dsChip`、`.textFieldStyle(.ds)` |
| `Tag`（`Format.swift`） | 圆角胶囊语义标签 |
| `DSAppearanceSettingsView` / `DSHolidaySettingsView` | 主应用与独立版万年历复用的外观与节假日设置视图 |

## 无标题栏窗口与双击行为（`WindowTitleBar`）

主窗口、设置窗口和各插件页面顶栏普遍使用 `.windowStyle(.hiddenTitleBar)`，并在顶栏空白处挂载 `WindowTitleBarArea` 或 `.windowTitleBar()`：
- 支持原生 `WindowDragGesture()` 拖拽移动窗口。
- 监听双击事件并与 macOS 系统设置 `AppleActionOnDoubleClick`（填充 `fill` / 最小化 `minimize` / 无操作 `none`）保持一致；填充与恢复旧 frame 状态由 `WindowTitleBarCoordinator` 管理，并带 0.15s 防抖。

## 状态栏弹层关闭（`MenuBarPopoverDismiss`）

`MenuBarExtra(.window)` 内容根视图挂载 `.menuBarPopoverDismissable()` 后，会向子视图环境注入 `\.dismissMenuBarPopover`（`MenuBarPopoverDismissAction`）：
- 点击需离开状态栏浮层的操作时调用 `dismissMenuBarPopover()`，通过 `MenuBarPopoverController` 优先执行 SwiftUI 原生 `dismiss()`，若对应的 `MenuBarExtra` 弹出窗口仍可见则调用 `NSWindow.close()` 关闭浮层。
- 关闭后自动检查并复位 `NSStatusBarButton` 可能残留的高亮/按下态，避免下次点击需要点击两次才能重新打开。

## 手账工作台视觉系统（`JournalStyle.swift`）

[`JournalStyle.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/UI/JournalStyle.swift) 为「汇报」分组下的「日报」「周报」「月报」提供双页活页手账界面底座，随系统浅色/深色模式自动切换：

- **设置键（`JournalKeys`）**：
  - `journal.paperPreset`（`JournalPaperPreset`，默认 `.warm`「暖米手账」，可选 `.clean`「清爽象牙」）
  - `journal.highlightedItems`（`[String]`，通过 `JournalHighlight.toggle(date:work:in:)` 持久化荧光笔重点，上限 200 条）
- **核心组件**：
  - `JournalPalette`：提供桌垫、皮革封边、书写纸/格纹纸、横线/网格、朱红/松绿/琥珀/紫色/靛蓝印章与便利贴语义色及衬线标题字体 `JournalPalette.serif(_:_:)`。
  - `JournalSpreadShell`：双页活页容器（左页格纹素材区 + 中央 6 环书脊 `JournalBinderSpine` + 右页横线书写区 + 右缘彩色索引签 `JournalIndexTabs`，宽度低于 `860pt` 时自动折叠为单页纵向布局），内置纸感预设切换胶囊、章节实心身份胶囊、`JournalStatusState` 高对比状态胶囊与右页顶部状态色带（未写态叠加朱红描边提示）。
  - `JournalStatusBanner` / `JournalStampBadge` / `JournalPaperCard` / `JournalStickyNote` / `JournalProgressBar` / `JournalPrimaryButtonStyle` / `JournalSecondaryButtonStyle`：未写/草稿/完成强视觉状态横幅、倾斜橡皮印章（带落印动画）、纸张小卡（支持色条、回形针与高亮态）、淡黄和纸便利贴、三段工时进度条与高对比手账按钮。
