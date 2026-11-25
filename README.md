# IronBowl
饭碗 — 我的上班工作台（macOS 26，SwiftUI + 液态玻璃）。

设计清单见 [docs/DESIGN.md](docs/DESIGN.md)。

## 构建

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project IronBowl.xcodeproj -scheme IronBowl -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/IronBowl.app
# 独立版万年历
xcodebuild -project IronBowl.xcodeproj -scheme Calendar -configuration Release -derivedDataPath build/DerivedData build
```

也可以 `xcodegen generate` 后用 Xcode 打开 `IronBowl.xcodeproj` 运行。

## 结构

- `Packages/IronBowlKit`：公共底座（插件协议、数据库、设置、提醒、工作日历、AI 提供者）
- `Packages/ZentaoLogPlugin`：禅道日志插件
- `Packages/CalendarPlugin`：万年历插件（农历、节气、节日、天气）
- `Apps/Calendar`：独立版万年历
- `Apps/IronBowl`：工作台应用

## 测试

```bash
(cd Packages/IronBowlKit && swift test)
(cd Packages/ZentaoLogPlugin && swift test)
# 扫描本机真实仓库：
(cd Packages/ZentaoLogPlugin && IRONBOWL_IT=1 swift test --filter localScanToday)
```

## 数据位置

- 数据库：`~/Library/Application Support/IronBowl/ironbowl.sqlite`
- 禅道接口日志：`~/Library/Application Support/IronBowl/logs/zentao.log`
