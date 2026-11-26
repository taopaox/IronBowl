# AI 网页目录插件（`AIWebPlugin`）

`AIWebPlugin`（`Packages/AIWebPlugin`）仿照 Cherry Studio 的侧栏目录交互，将主流大模型网页端聚合到工作台内，并共享全局网页登录态与墓碑内存回收机制。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `AIWebPlugin.swift` | `AIWebPlugin` | 声明 `isSidebarDirectory = true`，通过 `sidebarChildren` 在侧栏展示可折叠固定 AI 列表 |
| `AIWebModel.swift` | `AIWebModel`, `AIEditorTarget` | AI 列表管理、目录/应用切换、关闭会话（`closeApp(id:)` / `hasOpenSession(appID:)`）、增删改查、置顶排序、恢复预设与重置 |
| `AIWebModels.swift` | `AIWebKeys`, `AIWebApp`, `AICategory`, `AILogoSource` | 设置键、应用分类（通用对话/AI 搜索/编程开发/创作效率/自定义）与图标来源模型 |
| `AIWebPresets.swift` | `AIWebPresets` | 内置 20 个主流 AI 预设（附带打包在 `Resources/Logos` 中的官方图标） |
| `AILogoStore.swift` | `AILogoStore`, `AILogoError` | 管理包内 Logo、本地上传 PNG（`ai-logos/`）、远程 URL 缓存与网站 Favicon 自动抓取 |
| `Views/` | `AIWebMainView`, `AIAppEditorSheet`, `AIWebSettingsView`, `AILogoView` | AI 目录网格页、内嵌浏览顶栏、添加/编辑弹窗与设置管理页 |

## 内置预设与侧栏目录

- **20 个内置预设**（首次启动时 `AIWebKeys.apps == nil` 自动初始化）：
  - 默认固定到侧栏目录前 6 个：**ChatGPT**、**Claude**、**Gemini**、**DeepSeek**、**豆包**、**Kimi**。
  - 其余 14 个预设（未默认固定，可在目录页点击使用或固定）：通义千问、腾讯元宝、智谱清言、Perplexity、Grok、NotebookLM、Google AI Studio、Poe、Microsoft Copilot、文心一言、海螺 AI、扣子 Coze、讯飞星火、Mistral Le Chat。
- **目录与会话隔离**：每个应用会话 ID 为 `"aiweb.\(app.id)"`；在目录总览页（`activeAppID == nil`）可按分类筛选与管理，点击某项后进入 `WebContainerView` 浏览，后台闲置时由 `WebSessionManager` 自动墓碑休眠。
- **关闭已打开网页**：浏览页顶部工具栏右侧、休眠占位卡片、目录总览中已打开的 `AIAppCard`（卡片操作按钮与菜单）、以及左侧栏已固定目录子项均提供「关闭网页」操作，调用 `AIWebModel.closeApp(id:)` 销毁对应 `WebSession` 释放内存（正在查看该页时自动回到 AI 目录总览，关闭后台页不影响当前视图）。
- **自定义图标**：支持从内置图标选择、上传本地图片（统一归一化为 <=256px PNG）、填写远程图标链接或输入网址自动抓取 Favicon。
