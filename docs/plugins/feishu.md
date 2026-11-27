# 飞书知识库插件（`FeishuPlugin`）

`FeishuPlugin`（`Packages/FeishuPlugin`）将飞书网页版嵌入工作台主窗口，接入 `WebSessionManager` 墓碑内存管理，并支持把常用知识库或文档固定到工作台左侧栏。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `FeishuPlugin.swift` | `FeishuPlugin` | 插件入口，提供主视图、设置页、侧栏「固定网页」列表、首页卡片与快捷操作 |
| `FeishuModel.swift` | `FeishuModel` | 页面会话管理（主页 + 各固定页）、关闭会话（`closePage(id:navigateHomeIfActive:)` / `closeActivePage()` / `hasOpenSession(pageID:)`）、固定网页 CRUD、排序与休眠/免休眠控制 |
| `FeishuModels.swift` | `FeishuKeys`, `FeishuPinnedPage`, `FeishuURL` | 数据模型、预设图标选项与飞书网页标题后缀清理 |
| `Views/FeishuMainView.swift` | `FeishuMainView` | 顶部地址/工具栏（后退、前进、刷新、主页、一键固定到左侧、浏览器打开、立即休眠、关闭网页）+ `WebContainerView` + 已关闭空态页 |
| `Views/FeishuSettingsView.swift` | `FeishuSettingsView` | 飞书主页设置（含主页免休眠）与固定网页列表管理 |

## 核心特性

- **默认主页与桌面端防跳**：默认打开 `https://my.feishu.cn/`（可在设置中修改），`blockedSchemes = ["feishu", "lark"]` 自动拦截网页唤起飞书客户端的 URL Scheme。
- **固定到左侧栏**：在任意飞书页面点击工具栏固定按钮，即可保存当前 URL、清理标题后缀并展示在主窗口左侧栏「固定网页」分组。
- **立即休眠与关闭网页**：顶栏工具栏右侧均提供 `moon.zzz`「立即休眠」（将当前正在浏览的飞书页面立即转入墓碑卡片释放内存）与 `×`「关闭网页」按钮；左侧栏「飞书知识库」主行与各固定页支持悬停/右键菜单执行「立即休眠」「设为免休眠」「关闭网页」（关闭后立即销毁对应 `WebSession`，当前正在浏览时自动回到「今天」首页）。
- **设置键（`FeishuKeys`）**：`feishu.homeURL`、`feishu.homeNeverSuspend`、`feishu.pinnedPages`、`feishu.lastPageID`。
