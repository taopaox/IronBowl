# IronBowl（饭碗）项目文档

**IronBowl（饭碗）** 是基于 macOS 26 与 SwiftUI 原生开发的个人上班工作台，采用「共享底座 + 独立 Swift Package 插件 + 双应用宿主」架构，提供禅道工时日志自动生成、万年历与天气、飞书知识库、AI 网页目录（含内存墓碑休眠）以及独立版菜单栏万年历。

> 本目录由项目根目录 [AGENTS.md](../AGENTS.md) 约束维护；技术选型与阶段性设计清单见 [DESIGN.md](./DESIGN.md)。

## 文档目录结构

```text
docs/
├── README.md                         # 文档总索引（本文件）
├── DESIGN.md                         # 设计清单（各阶段范围与核心约束）
├── architecture/                     # 架构与底座规范
│   ├── overview.md                   # 模块划分、依赖关系与插件协议
│   ├── data-and-storage.md           # SQLite 存储、迁移、设置与跨进程同步
│   └── design-system.md              # 视觉规范、颜色字体与 DS* 组件库
├── core/                             # IronBowlKit 公共底座能力
│   ├── ai-provider.md                # AI 提供者配置与只读结构化执行
│   ├── chat.md                       # 首页多对话引擎、流式事件解析与持久化
│   ├── work-calendar.md              # 工作日历、上下班工时、弹性打卡（钉钉 dws）与节假日数据源
│   ├── web-tombstone.md              # 内嵌网页会话与 Chrome 式墓碑休眠机制
│   ├── scheduler.md                  # 通用定时任务调度引擎（周期计算、补跑与内置动作）
│   └── reminders.md                  # 提醒中心（系统通知与浮动面板）
├── plugins/                          # 业务插件文档
│   ├── zentao-log.md                 # 禅道日志插件（Git 扫描、AI 草稿、加班拆条、接口）
│   ├── calendar.md                   # 万年历插件（农历、24 节气、节日、天气、弹层）
│   ├── feishu.md                     # 飞书知识库插件（内嵌网页与固定网页）
│   ├── ai-web.md                     # AI 网页目录插件（20 个预设、Logo 与侧栏目录）
│   ├── scheduler.md                  # 定时任务插件（任务管理、编辑器与执行记录）
│   ├── report.md                     # 周报月报与述职插件（周/月日报汇总、季度年报、牛马账本）
│   ├── todo.md                       # 待办与备忘插件（与万年历、禅道日报及提醒中心联动）
│   └── scratchpad.md                 # 随手便签插件（剪贴板暂存、Markdown 预览与 JSON 格式化）
├── apps/                             # 可执行应用宿主
│   ├── ironbowl.md                   # 饭碗主工作台应用（Apps/IronBowl）
│   └── standalone-calendar.md        # 独立版万年历应用（Apps/Calendar）
└── development/                      # 开发、构建与扩展指南
    ├── getting-started.md            # 本地构建、运行与测试指南
    └── plugin-guide.md               # 新增功能插件开发指南
```

## 快速导航

| 主题 | 文档 | 说明 |
| :--- | :--- | :--- |
| 整体架构与插件协议 | [架构总览](./architecture/overview.md) | Package 依赖、`project.yml`、`IronBowlPlugin` 与 `PluginContext` |
| 数据库与跨进程同步 | [数据与存储](./architecture/data-and-storage.md) | `AppDatabase`、表结构迁移、`SettingsStore`、本地日志路径 |
| UI 组件与缩放规范 | [设计系统](./architecture/design-system.md) | `DS*` 组件、浅深色适配、字体缩放与无标题栏窗口拖拽 |
| AI 调用能力 | [AI 提供者](./core/ai-provider.md) | `agy` / `codex` 只读 JSON Schema 调用与自动路径探测 |
| 多对话引擎 | [首页多对话工作台](./core/chat.md) | `ChatStore`、`AIChatRunner`、`AIChatStreamParser` 与 `Shell.streamLines` |
| 节假日与工时计算 | [工作日历](./core/work-calendar.md) | 默认工时公式、弹性下班与钉钉考勤同步、`DayInfo` 优先级与节假日抓取源 |
| 网页内存回收 | [网页与墓碑机制](./core/web-tombstone.md) | `WebSessionManager`、LRU/闲置休眠、快照与历史栈恢复 |
| 定时任务底座 | [定时任务调度引擎](./core/scheduler.md) | `TaskScheduler`、工作日/循环周期计算、防重槽位与补执行策略 |
| 多样式提醒 | [提醒中心](./core/reminders.md) | 系统通知、右上角卡片、屏幕中央弹框 |
| 核心插件 | [禅道日志](./plugins/zentao-log.md) | Git 扫描、当日工时/加班拆条生成、禅道 JSON 接口、提醒与定时自动提交 |
| 历法与天气 | [万年历](./plugins/calendar.md) | 中国历法、Meeus 节气、Open-Meteo/和风天气、菜单栏弹层 |
| 知识库集成 | [飞书知识库](./plugins/feishu.md) | 方案拦截、上传下载、固定网页到工作台侧边栏 |
| AI 网页聚合 | [AI 目录](./plugins/ai-web.md) | 侧栏可折叠目录、20 个预设、本地/远程 Logo 管理 |
| 自动化任务 | [定时任务](./plugins/scheduler.md) | 任务列表、动态动作参数编辑器、执行日志审计与菜单栏倒计时 |
| 周报、月报、账本与述职 | [周报、月报与账本](./plugins/report.md) | 独立「周报」「月报」「牛马账本」「季度/年报」菜单：周/月日报汇总、直连 Tita、工时打卡看板与述职/年度报告 |
| 待办与备忘 | [待办与备忘](./plugins/todo.md) | 跨万年历与禅道日报共享的待办日程、逾期统计、定时提醒与一键转入日报草稿 |
| 随手便签 | [随手便签](./plugins/scratchpad.md) | 全局 `⌃⌥⌘N` 悬浮便签、剪贴板暂存、JSON 美化/压缩、Markdown 预览及转待办/转日报 |
| 宿主应用 | [工作台主应用](./apps/ironbowl.md) · [独立版万年历](./apps/standalone-calendar.md) | 窗口、菜单栏、程序坞策略、开机自启与双应用数据共享 |
| 开发与测试 | [开发与测试指南](./development/getting-started.md) · [插件开发指南](./development/plugin-guide.md) | XcodeGen、`xcodebuild`、`swift test` 与新插件接入步骤 |

## 常用本地路径

- **共享数据库**：`~/Library/Application Support/IronBowl/ironbowl.sqlite`
- **应用日志目录**：`~/Library/Application Support/IronBowl/logs/`（含禅道接口调试日志 `zentao.log`、Tita 接口调试日志 `tita.log`）
- **AI 图标目录**：`~/Library/Application Support/IronBowl/ai-logos/`
- **个人头像目录**：`~/Library/Application Support/IronBowl/user-avatars/`
- **默认 Debug 构建产物**：`build/DerivedData/Build/Products/Debug/IronBowl.app` 与 `IronBowlCalendar.app`
