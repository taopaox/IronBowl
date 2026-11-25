# 插件开发指南

IronBowl 的所有业务功能均以独立 Swift Package 的形式实现 [`IronBowlPlugin`](../../Packages/IronBowlKit/Sources/IronBowlKit/Core/Plugin.swift) 协议并挂载到主工作台。

## 1. 创建 Swift Package

在 `Packages/<YourPlugin>/` 下创建 `Package.swift`、`Sources/<YourPlugin>/` 与 `Tests/<YourPlugin>Tests/`，保持与其他插件一致的并发编译配置：

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TodoPlugin",
    platforms: [.macOS("26.0")],
    products: [.library(name: "TodoPlugin", targets: ["TodoPlugin"])],
    dependencies: [.package(path: "../IronBowlKit")],
    targets: [
        .target(
            name: "TodoPlugin",
            dependencies: ["IronBowlKit"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(name: "TodoPluginTests", dependencies: ["TodoPlugin"]),
    ]
)
```

## 2. 实现 `IronBowlPlugin` 协议

- 提供稳定唯一的 `id`、`title`、`systemImage`。
- 如需持久化业务表，通过 `migrations: [DatabaseMigration]` 注册带插件前缀的迁移标识（如 `"todo.v1"`）。
- 在 `start(context: PluginContext)` 初始化状态管理器，并在 `stop()` 中清理定时器、后台任务与 `WebSessionManager` 会话。
- 界面一律使用 `IronBowlKit` 提供的 `DS*` 组件与 `DS.*` 颜色/字号令牌（见 [设计系统](../architecture/design-system.md)）。
- 如插件需内嵌网页，务必使用 `context.webSessions` + `WebContainerView` 以自动纳入全局墓碑内存回收。

## 3. 注册到工程与宿主

1. **配置 [`project.yml`](../../project.yml)**：
   - 在 `packages:` 下添加本地包路径。
   - 在 `targets.IronBowl.dependencies:` 中引用该 package。
2. **重新生成工程**：运行 `xcodegen generate`。
3. **注册插件实例**：在 [`Apps/IronBowl/AppModel.swift`](../../Apps/IronBowl/AppModel.swift) 的 `plugins` 数组中添加实例（若替换掉对应的 `ComingSoonPlugin` 占位项，请沿用或平滑迁移其 `id`）。

## 4. 测试与文档更新

1. 在 `Packages/<YourPlugin>/Tests/` 下编写 Swift Testing 单元测试并确认 `swift test --package-path Packages/<YourPlugin>` 全部通过。
2. 在 `docs/plugins/` 新增对应插件文档并更新 [`docs/README.md`](../README.md) 索引（遵循根目录 [AGENTS.md](../../AGENTS.md) 规范）。
3. 使用 `xcodebuild -project IronBowl.xcodeproj -scheme IronBowl -configuration Debug -derivedDataPath build/DerivedData build` 构建并本地启动验证。
