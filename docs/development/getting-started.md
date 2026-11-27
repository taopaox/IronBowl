# 本地开发、构建与测试指南

## 环境要求

- **系统**：macOS 26.0+
- **工具链**：Xcode（支持 Swift 6.2 / macOS 26 SDK）
- **工程生成工具**：XcodeGen（用于根据 [`project.yml`](../../project.yml) 生成 `IronBowl.xcodeproj`）

```bash
brew install xcodegen
xcodegen generate
git config core.hooksPath .githooks
```

## 分支与协作流

- **`dev` 为日常开发主分支**：新功能与修复均在 `dev`（或从 `dev` 切出的 `feat/*`、`fix/*` 分支）开发提交。
- **`main` 仅接受合并或 PR**：启用 `.githooks` 后，本地会阻止在 `main` 上直接提交或直接推送非合并提交；只有合入 `main`（包括 PR 合并或分支合并推送）时才触发 GitHub Actions 自动升级版本号、编译双应用并发布 Release。
- **发版合入支持自提自批**：从 `dev` 向 `main` 提 PR 后，可直接执行 `gh pr merge <PR号> --merge`（保留 `dev` 分支）完成合并并等待发版流水线同步回 `dev`。
- **一键发版工作区 Skill**：项目在 [`.agents/skills/release/SKILL.md`](../../.agents/skills/release/SKILL.md) 提供 `release` 技能，口述「发版」即可自动完成提交改动、推送 `dev`、提 PR 合入 `main`、跟踪发版流水线并同步版本提交回 `dev`。

## 自动版本升级与 GitHub Actions 发布

- **自动发版流水线（[`.github/workflows/release.yml`](../../.github/workflows/release.yml)）**：仅在 `main` 收到合并推送（或手动 `workflow_dispatch`）时自动执行 [`scripts/release.py`](../../scripts/release.py)：
  - 扫描上一个 `v*` Tag 至 `HEAD` 间的非合并提交（跳过 `chore(release):` 提交）并按约定式提交规则计算新版本号（含 `BREAKING CHANGE` / `!` 规则与 `0.x` 次版本递增规则）、递增 `CURRENT_PROJECT_VERSION`；
  - 更新 [`project.yml`](../../project.yml) 并重新生成 Xcode 工程，直接 Release 编译并校验 `IronBowl.app` 与 `IronBowlCalendar.app` 的 `Info.plist` 版本、`CFBundleDisplayName`、`CFBundleName`、`LSHasLocalizedDisplayName`、`SUFeedURL` 与 `SUPublicEDKey`（两款应用通过 `LSHasLocalizedDisplayName` 与各自的 `InfoPlist.strings` 在访达、程序坞与系统界面中显示为「饭碗」与「万年历」；单元测试在合入前于本地执行，CI 跳过重复单测以缩短发版耗时）；
  - 为两款应用分别打包 `.dmg` 与 `.zip` 安装包及 `SHA256SUMS.txt`，使用仓库 Secret `SPARKLE_PRIVATE_KEY` 调用 Sparkle `sign_update` 对两份 `.zip` 进行 Ed25519 签名，并通过 `scripts/release.py appcast` 生成 `appcast-ironbowl.xml` 与 `appcast-calendar.xml`；
  - 提交 `chore(release): 发布 vX.Y.Z`、创建 `vX.Y.Z` Tag 并发布 GitHub Release（标题为 `饭碗 vX.Y.Z`，通过 `#label` 为安装包展示中文名 `饭碗-vX.Y.Z-macOS-arm64.{dmg,zip}` 与 `万年历-vX.Y.Z-macOS-arm64.{dmg,zip}`，底层保持 ASCII 文件名以兼容 GitHub 上传、SHA-256 校验与 Sparkle 更新源；附中文分类更新日志，两份 `appcast-*.xml` 一并作为 Release 附件托管以供双应用 Sparkle 2 客户端免鉴权自动更新）。

## 本地构建与运行

### 主工作台应用（`IronBowl`）

Debug 构建到 `build/DerivedData` 并重启运行（开发期常规验证路径）：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme IronBowl -configuration Debug -derivedDataPath build/DerivedData build
(pkill -x IronBowl || true) && sleep 0.5 && open build/DerivedData/Build/Products/Debug/IronBowl.app
```

Release 构建：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme IronBowl -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/IronBowl.app
```

### 独立版万年历（`Calendar`）

Debug 构建并重启：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme Calendar -configuration Debug -derivedDataPath build/DerivedData build
(pkill -x IronBowlCalendar || true) && sleep 0.5 && open build/DerivedData/Build/Products/Debug/IronBowlCalendar.app
```

Release 构建：

```bash
xcodebuild -project IronBowl.xcodeproj -scheme Calendar -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/IronBowlCalendar.app
```

## 运行单元测试

各 Swift Package 均可独立使用 `swift test`（采用 Swift Testing 框架）运行测试：

```bash
swift test --package-path Packages/IronBowlKit
swift test --package-path Packages/ZentaoLogPlugin
swift test --package-path Packages/CalendarPlugin
swift test --package-path Packages/FeishuPlugin
swift test --package-path Packages/AIWebPlugin
swift test --package-path Packages/SchedulerPlugin
```

### 依赖本机环境的集成测试（默认跳过）

部分测试需要真实本地仓库、禅道账号或外网天气接口，通过环境变量开关触发：

```bash
# 扫描本机真实 Git 仓库
(cd Packages/ZentaoLogPlugin && IRONBOWL_IT=1 swift test --filter localScanToday)
```

## 调试与数据排查

- **数据库检查**：使用 SQLite 客户端打开 `~/Library/Application Support/IronBowl/ironbowl.sqlite`。
- **禅道接口日志**：可在设置页「禅道账号 → 打开接口日志」或直接查看 `~/Library/Application Support/IronBowl/logs/zentao.log`（自动屏蔽密码）。
- **清理网页登录态**：可在「设置 → 网页与内存 → 清除登录缓存」清空 `WKWebsiteDataStore.default()` 数据。
