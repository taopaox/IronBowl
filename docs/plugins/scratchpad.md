# 随手便签插件（`ScratchpadPlugin`）

`ScratchpadPlugin`（`Packages/TodoPlugin`）提供工作台随手便签、剪贴板历史监听与常用片段库，适合日常暂存 JSON 报文、测试账号、curl 命令、会议碎片笔记，并与待办、禅道日报草稿互通。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `IronBowlKit/Todo/ScratchpadStore.swift` | `ScratchpadStore`, `ScratchpadNote`, `ScratchpadColorTag` | 持久化于核心表 `scratchpadNote`（`core.v9`），支持置顶排序、JSON 美化/压缩与标题自动推导 |
| `IronBowlKit/Todo/ClipboardHistoryStore.swift` | `ClipboardHistoryStore`, `ClipboardHistoryItem`, `ClipboardContentKind`, `ClipboardKeys` | 持久化于核心表 `clipboardHistory`（`core.v11`），定时监听剪贴板变更、跳过密码管理器/密文类型、SHA256 去重与常用片段永久保留 |
| `TodoPlugin/ScratchpadPlugin.swift` | `ScratchpadPlugin`, `QuickScratchpadCapture`, `ScratchpadSettingsView` | 插件入口、全局快捷键 `⌃⌥⌘N` 悬浮便签窗、首页概览卡、剪贴板开关配置与快捷操作 |
| `TodoPlugin/Views/ScratchpadMainView.swift` | `ScratchpadMainView` | 顶部三栏切换「便签笔记 / 剪贴板历史 / 常用片段」：搜索、颜色与类型筛选、JSON 工具、一键复制/存为便签/固定片段及转待办/转日报 |

## 设置键

- `scratchpad.quickShortcut`：启用随手便签全局快捷键 `⌃⌥⌘N`（默认 `true`）。
- `clipboard.enabled`：开启剪贴板历史监听（默认 `true`）。
- `clipboard.maxCount`：非片段剪贴板历史保留上限（默认 `200`）。
