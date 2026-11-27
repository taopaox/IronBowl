# 本地仓库工作台插件（`WorkspacePlugin`）

`WorkspacePlugin`（`Packages/WorkspacePlugin`）为研发提供集中式的本地 Git 仓库面板，归入主窗口左侧栏「研发」分组，复用禅道日志的仓库发现、状态巡检与项目映射数据，实现一键启动编辑器、终端、访达与首页 AI 对话。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `WorkspacePlugin.swift` | `WorkspacePlugin` | 插件入口（`id = "workspace"`，`sidebarSection = "研发"`），提供待处理角标、首页卡片与快捷操作 |
| `WorkspaceModels.swift` | `WorkspaceKeys`, `ExternalEditorOption`, `ExternalTerminalOption`, `WorkspaceRepoItem`, `WorkspaceRepoSorter` | 编辑器/终端自动探测、状态模型与「收藏 → 待处理 → 今日活跃 → 名称」排序筛选纯函数 |
| `WorkspaceModel.swift` | `WorkspaceModel` | 并发汇总仓库分支、未提交/未推送数、最近提交及禅道关联项目名；执行外部打开与 `git fetch --prune` |
| `Views/WorkspaceMainView.swift` | `WorkspaceMainView`, `WorkspaceSettingsView` | 仓库指标与筛选卡片列表、多编辑器切换菜单、AI 对话快捷跳转及设置页 |

## 设置键（`WorkspaceKeys`）

- `workspace.defaultEditor`：默认外部编辑器（`"auto"` / `"cursor"` / `"vscode"` / `"windsurf"` / `"zed"` / `"xcode"` / `"idea"` / `"androidStudio"`）。
- `workspace.defaultTerminal`：默认终端应用（`"auto"` / `"ghostty"` / `"iterm"` / `"warp"` / `"terminal"`）。
- `workspace.pinnedRepos`：收藏置顶的仓库路径列表。
- `workspace.extraRepos`：除禅道扫描目录之外手动添加的仓库路径列表。
