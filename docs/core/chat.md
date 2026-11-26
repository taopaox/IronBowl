# 首页多对话工作台底座（`Chat`）

首页「今天」的多轮 AI 对话能力由 [`Packages/IronBowlKit/Sources/IronBowlKit/Chat/`](../../Packages/IronBowlKit/Sources/IronBowlKit/Chat) 提供，基于 SQLite 持久化、流式子进程执行与统一 JSONL 事件解析，支持多对话并行运行、工作目录绑定、读写/只读权限切换及工作台功能卡片插入。

## 核心模块

| 文件 | 核心类型 | 职责 |
| :--- | :--- | :--- |
| `ChatModels.swift` | `ChatThread`, `ChatMessage`, `ChatActivityItem`, `ChatCardAttachment`, `ChatPermissionMode`, `ChatOutputDetailLevel`, `ChatTokenUsage`, `ChatKeys` | 定义对话线程、消息角色与状态、活动条目、功能卡片快照与设置键 |
| `AIChatStreamParser.swift` | `AIChatStreamParser`, `AIChatStreamEvent` | 将 `agy --output-format stream-json` 与 `codex exec --json` 的 NDJSON 行解析为统一事件流 |
| `AIChatRunner.swift` | `AIChatRunner` | 组装首次/续聊命令行参数并通过 `Shell.streamLines` 在指定工作目录流式执行 |
| `ChatStore.swift` | `ChatStore` | 管理对话列表、当前选中对话、后台并行任务、中止/重试及 GRDB 持久化 |

## 流式执行与会话续聊

1. **进程流式管道**：[`Shell.streamLines`](../../Packages/IronBowlKit/Sources/IronBowlKit/Core/Shell.swift) 通过 `Pipe.readabilityHandler` 与 `LineCollector` 按行实时回调 stdout/stderr，并暴露 `ShellProcessHandle` 供界面随时终止子进程（`SIGTERM` 后超时补 `SIGKILL`）。
2. **命令行参数策略（`AIChatRunner.buildArguments`）**：
   - **`agy`**：使用 `-p <prompt> --output-format stream-json`，续聊时追加 `--resume <conversation_id>`；`ChatPermissionMode.agent` 传 `--dangerously-skip-permissions`，`.readOnly` 传 `--sandbox`。
   - **`codex`**：首次会话使用 `exec --skip-git-repo-check -s <workspace-write|read-only> -c approval_policy="never" --json -C <workspacePath>`；续聊使用 `exec resume --skip-git-repo-check --json -c sandbox_mode="..." -c approval_policy="never" <thread_id> <prompt>`（工作目录通过子进程 `cwd` 传入）。
3. **上下文兜底**：若用户中途切换 `providerKind`（`ChatStore.updateThread` 会清空 `remoteSessionID`）或尚无远端会话 ID，`ChatStore.composePrompt` 会自动拼接最近最多 6 条历史消息及随条附加的功能卡片信息。

## 输出详情与详略模式

- **活动明细（`ChatActivityItem`）**：记录思考（`.thinking`）、命令（`.command` 含退出码 `exitCode`）、工具（`.tool`）、文件改动（`.fileChange`）、阶段说明（`.note`）与错误（`.error`），单条输出内容按 `32,768` 字符截断保留末尾，原始 JSONL 行最多保留最近 160 行。
- **详略模式（`ChatOutputDetailLevel`）**：
  - `.all`：默认展开全部执行详情。
  - `.hideSuccessful`：运行中展开，完成后自动折叠已成功步骤，仅保留失败项。
  - `.zen`：完成后折叠全部中间过程，仅保留摘要徽标与最终回复。
