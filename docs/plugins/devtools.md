# 研发工具箱插件（`DevToolsPlugin`）

`DevToolsPlugin`（`Packages/DevToolsPlugin`）归入主窗口左侧栏「研发」分组，提供本地监听端口管理与常用离线开发转换工具，避免把公司内部报文或 Token 粘贴到未知在线网站。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `DevToolsPlugin.swift` | `DevToolsPlugin`, `DevToolsModel` | 插件入口（`id = "devtools"`，`sidebarSection = "研发"`），聚合开发目录（自动同步 `git.root`、`workspace.extraRepos` 与自定义 `devtools.devDirectories`），提供设置页 `devtools.settings`、菜单栏关注端口项 `devtools.ports`、首页卡片与快捷入口 |
| `PortScanner.swift` | `PortScanner`, `PortDirectoryMatcher`, `ListeningPortItem`, `GroupedListeningPort`, `PortPartition`, `PortGroupScope`, `DevDirectoryEntry`, `DevToolsKeys`, `PortActionError` | 解析 `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcnLu`、`lsof -d cwd` 与 `/bin/ps -ww` 参数，按进程工作目录或启动命令归入「我的开发目录」与「其他监听端口」分组，并支持安全终止进程（拒绝 `PID <= 1` 与自身进程） |
| `DevConverters.swift` | `DevConverters`, `TimestampInfo`, `DecodedJWTResult`, `DiffLine` | 离线纯函数：秒/毫秒时间戳互转、JWT Base64URL 解码与过期校验、Base64/URL/Unicode/SHA256/MD5/UUID 及 LCS 行级文本 Diff |
| `Views/DevToolsMainView.swift` | `DevToolsMainView`, `DevToolsSettingsView` | 顶栏 5 切换面板（端口管家 / 时间戳 / JWT 解析 / 编解码与哈希 / 文本对比），端口管家支持「全部分组 / 我的开发目录 / 其他端口」筛选与目录管理浮层；设置页支持配置开发目录与常用关注端口 |

## 设置键（`DevToolsKeys`）

- `devtools.watchedPorts`：常用关注开发端口列表（默认 `[3000, 5173, 8000, 8080, 8888]`）。
- `devtools.devDirectories`：用户额外自定义的本地开发目录列表（默认 `[]`，与禅道仓库根目录 `git.root` 及代码仓库 `workspace.extraRepos` 共同参与「我的开发目录」端口检查分组）。
