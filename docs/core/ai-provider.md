# AI 提供者（`AIProvider`）

AI 执行能力由 [`AIProvider.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/AI/AIProvider.swift) 与 [`Shell.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Core/Shell.swift) 提供，支持以统一提示词和 JSON Schema 调用本地安装的 AI CLI，且全部在隔离临时目录中以只读方式运行。

> 本页介绍供插件使用的只读结构化执行器 `AIRunner`；首页「今天」的多轮交互式流式对话与本地工作目录执行能力由 [`AIChatRunner`](./chat.md) 提供。

## 支持的提供者（`AIProviderKind`）

| 枚举 | 显示名 | 可执行文件名 | 默认思考深度选项 |
| :--- | :--- | :--- | :--- |
| `.agy` | `Antigravity（agy）` | `agy` | `""`、`low`、`medium`、`high`、`xhigh`、`max` |
| `.codex` | `Codex` | `codex` | `""`、`minimal`、`low`、`medium`、`high` |

每个提供者的配置（`AIProviderConfig`）包含：`executablePath`、`model`、`effort`（默认 `"low"`）、`timeoutSeconds`（默认 `90` 秒）与 `extraArgs`。

## 配置存储与自动探测（`AIProviderStore`）

- 设置键：`ai.providers`（`[AIProviderConfig]`）、`ai.default`（默认 `.agy`）。
- 应用启动时 `AppModel` 调用 `autodetectMissingPaths()`，对路径为空的提供者使用 `Shell.which(kind.binaryName)`（通过登录 shell `zsh -lc 'command -v ...'`，兼容 Homebrew / nvm PATH）自动回填可执行路径；随后调用 `loadAllModels()` 预加载各提供者可用模型缓存（`availableModels`）。

## 只读执行与结构化解析（`AIRunner`）

调用入口：`AIRunner.run(config:prompt:schema:) -> AIRunResult`（返回符合 schema 的 JSON `Data` 与耗时 `duration`）：

1. 为每次调用创建临时目录 `/tmp/ironbowl-ai-<UUID>` 并在退出时自动删除，保证 CLI 不接触工作区与代码仓库。
2. 按提供者类型拼接只读参数：
   - **`agy`**：`-p <prompt> --output-format json --json-schema <schema> --sandbox --disable-slash-commands`，可选 `--model` / `--effort` 与 `extraArgs`；通过 `parseAgy` 校验 `"status":"SUCCESS"` 并提取 `structured_output` 或 `response` 中的 JSON。
   - **`codex`**：写入临时 `schema.json` 与 `out.json`，执行 `exec --skip-git-repo-check -s read-only --output-schema ... -o ... -C <tempDir>`；通过 `extractJSONObject` 提取首个完整 JSON 对象。
3. **可用模型发现（`AIModelInfo`）**：
   - `AIRunner.listModelInfos(config:)` 统一返回 `[AIModelInfo]`（含 `id`、`name`、`detail`、`supportedEfforts`）：
     - **`agy`**：执行 `agy models` 并由 `parseAgyModels(_:)` 解析制表符或多空格分隔的模型列表；
     - **`codex`**：读取 `$CODEX_HOME/models_cache.json`（默认 `~/.codex/models_cache.json`），由 `parseCodexModelsCache(_:)` 过滤 `visibility != "hide"` 并按 `priority` 排序。
   - `AIRunner.listModels(config:)` 复用 `listModelInfos` 返回 `(id, name)` 元组供兼容使用；`AIProviderStore.loadModels(for:force:)` 与 `availableModels` 为设置页与首页对话底栏提供响应式模型缓存。
