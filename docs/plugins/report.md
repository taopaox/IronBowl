# 周报插件（`ReportPlugin`）

`ReportPlugin`（`Packages/ReportPlugin`）负责按周（周一至周日）汇总每日工作日报并生成结构化周报，支持直接复用禅道远端工时、本地已提交记录与未提交草稿，提供 AI 智能提炼与本地规则兜底汇总。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `ReportPlugin.swift` | `ReportPlugin` | 插件入口（ID：`report`）、首页快捷操作「生成本周周报」、首页概览卡片「本周周报」与设置页入口 |
| `ReportModel.swift` | `WeeklyReportModel` | `@Observable` 业务状态：周切换、调用 `ZentaoDailyLogService` 查本周日报、生成/编辑/自动保存、历史列表、复制与导出 Markdown |
| `Model/WeekRange.swift` | `WeekRange` | 按中国工作周（周一至周日）与 ISO 周历计算起止日期、周次标题、上下周偏移及「本周 / 上周」标签 |
| `Store/ReportStore.swift` | `WeeklyReportStyle`, `ReportKeys`, `WeeklyReportRecord`, `ReportMigrations`, `ReportStore` | 设置键、数据库迁移 `report.v1`（表 `weeklyReport`）及按周持久化读写 |
| `Generator/WeeklyReportGenerator.swift` | `DailyReportDay`, `WeeklyReportInput`, `WeeklyReportOutput`, `WeeklyReportGenerator` | 提示词模板渲染、只读 JSON Schema AI 生成与 3 种风格的规则兜底汇总 |
| `Views/ReportView.swift` | `ReportView` | 响应式双栏周报工作区：左侧汇总本周 7 天每日日报与工时覆盖，右侧常驻展示补充说明与文档纸张式周报预览/编辑区，支持历史弹层、复制与导出 |
| `Views/ReportSettingsView.swift` | `ReportSettingsView` | 设置页「周报 → 周报生成」：默认周报风格、草稿/工时开关与自定义提示词编辑 |

## 本周每日日报查询机制

`WeeklyReportModel` 通过 `ZentaoLogPlugin` 暴露的 `ZentaoDailyLogService` 按当前周的闭区间 `[weekStart, weekEnd]` 查询每日日报：

1. **本地即时加载（`loadLocal`）**：读取 `zentaoSubmission`（已提交工时）及可选的 `zentaoPendingDraft`（未提交草稿），结合 `zentaoRepoMapping` 立即构建本周 7 天日报视图。
2. **禅道远端同步（`fetch`）**：若已配置禅道账号，并发拉取 `myTasks()`、`finishedTasks()` 与 `myEstimates(since: weekStart, taskIDs: ...)`，与本地记录按任务 ID、工时及工作内容归一化去重，合并保留本地加班标记 `isOvertime` 并补齐项目名称与任务标题。
3. **草稿纳入控制**：可通过 `report.includeDrafts`（页内「包含未提交草稿」勾选框或设置页开关）随时控制是否把禅道日志页的未提交草稿纳入周报汇总。

## 周报生成与风格（`WeeklyReportGenerator`）

- **三种周报风格（`WeeklyReportStyle`）**：
  - `.standard`（**标准周报**）：按项目/模块归类本周完成工作，附工时统计（可选）、问题与风险及下周工作计划。
  - `.byProject`（**按项目汇总**）：按禅道项目分小节汇报成果并统计项目工时。
  - `.concise`（**精简要点**）：紧凑的编号要点列表与简明工时结论，适合直接粘贴发送到飞书或钉钉群。
- **AI 生成与本地兜底**：
  - 配置了 `agy` 或 `codex` 时，调用 `AIRunner.run`（JSON Schema 要求返回 `title` 与 `content`）合并去重多日持续推进的工作并提炼业务产出。
  - 未配置 AI 或 CLI 执行失败时，自动降级为 `fallbackReport` 按项目分组、拆行去重生成结构化 Markdown 周报，不阻塞汇报流程。
- **自定义提示词占位符**：`{{weekRange}}`、`{{totalHours}}`、`{{styleInstruction}}`、`{{dailyLogs}}`、`{{extraNotes}}`。

## 持久化与设置键（`ReportKeys`）

- **数据库表**：`weeklyReport`（迁移 `report.v1`，主键 `weekStart` `yyyy-MM-dd`），保存每周周报标题、正文、补充说明、风格、生成来源、工时合计及时间戳。
- **设置键**：
  - `report.style`（默认 `.standard`）
  - `report.includeDrafts`（默认 `true`）
  - `report.includeHours`（默认 `true`）
  - `report.prompt`（默认 `WeeklyReportGenerator.defaultPrompt`）
