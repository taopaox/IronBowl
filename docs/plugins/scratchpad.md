# 随手便签插件（`ScratchpadPlugin`）

`ScratchpadPlugin`（`Packages/TodoPlugin`）提供工作台随手便签与剪贴板暂存板，适合日常暂存 JSON 报文、测试账号、curl 命令、会议碎片笔记，并与待办、禅道日报草稿互通。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `IronBowlKit/Todo/ScratchpadStore.swift` | `ScratchpadStore`, `ScratchpadNote`, `ScratchpadColorTag` | 持久化于核心表 `scratchpadNote`（`core.v9`），支持置顶排序、JSON 美化/压缩与标题自动推导 |
| `TodoPlugin/ScratchpadPlugin.swift` | `ScratchpadPlugin`, `QuickScratchpadCapture`, `ScratchpadSettingsView` | 插件入口、全局快捷键 `⌃⌥⌘N` 悬浮便签窗、首页概览卡与快捷操作 |
| `TodoPlugin/Views/ScratchpadMainView.swift` | `ScratchpadMainView` | 左右双栏便签工作区：搜索、颜色标签筛选、从剪贴板新建、Markdown 预览、JSON 工具、转待办/转日报草稿 |

## 设置键

- `scratchpad.quickShortcut`：启用随手便签全局快捷键 `⌃⌥⌘N`（默认 `true`）。
