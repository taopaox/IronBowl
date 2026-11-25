# 周报与月报插件（`ReportPlugin` & `MonthlyReportPlugin`）

`Packages/ReportPlugin` 同时提供两个独立侧边栏插件——**周报**（`ReportPlugin`，ID：`report`）与 **月报**（`MonthlyReportPlugin`，ID：`report.monthly`），复用同一套日报查询与生成底座，分别按周（周一至周日）或按自然月（1 日至月末）汇总每日工作日报并生成结构化报告，支持复用禅道远端工时、本地已提交记录、未提交草稿与本月已有周报，提供 AI 智能提炼与本地规则兜底汇总。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `ReportPlugin.swift` | `ReportPlugin`, `MonthlyReportPlugin` | 两个独立侧边栏插件入口：周报（ID：`report`，锁定 `.weekly`）与月报（ID：`report.monthly`，锁定 `.monthly`），各自提供对应设置页、首页快捷操作与概览卡片 |
| `ReportModel.swift` | `WeeklyReportModel` | `@Observable` 业务状态：支持 `lockedPeriodKind` 锁定周/月模式、上下周与上下月切换、调用 `ZentaoDailyLogService` 查区间日报、生成/编辑/自动保存、历史列表、复制与导出 Markdown |
| `Model/WeekRange.swift` | `WeekRange` | 按中国工作周（周一至周日）与 ISO 周历计算起止日期、周次标题、上下周偏移及「本周 / 上周」标签 |
| `Model/MonthRange.swift` | `MonthRange`, `MonthWeekSlice` | 按自然月（1 日至月末）计算起止日期、周分片（`weeks`）、上下月偏移及「本月 / 上月」标签 |
| `Store/ReportStore.swift` | `ReportPeriodKind`, `WeeklyReportStyle`, `ReportKeys`, `WeeklyReportRecord`, `MonthlyReportRecord`, `ReportMigrations`, `ReportStore` | 设置键、拆分迁移 `ReportMigrations.weekly`（`report.v1` / `weeklyReport`）与 `ReportMigrations.monthly`（`report.v2` / `monthlyReport`）及读写操作 |
| `Generator/WeeklyReportGenerator.swift` | `DailyReportDay`, `WeeklyReportInput`, `MonthlyReportInput`, `WeeklyReportOutput`, `WeeklyReportGenerator` | 周报/月报提示词模板渲染、只读 JSON Schema AI 生成与 3 种风格的规则兜底汇总 |
| `Views/ReportView.swift` | `ReportView` | 响应式双栏工作区：顶栏在独立菜单中固定展示「周报」或「月报」与对应历史弹层，左栏展示周期汇总、7 天/按周分片筛选条与每日日报明细，右栏常驻展示补充说明与文档纸张式预览/编辑区 |
| `Views/ReportSettingsView.swift` | `ReportSettingsView` | 按 `periodKind` 分别呈现「周报 → 周报生成」与「月报 → 月报生成」设置页：默认风格、草稿/工时开关与对应提示词编辑 |

## 周期日报查询机制

`WeeklyReportModel` 通过 `ZentaoLogPlugin` 暴露的 `ZentaoDailyLogService` 按当前周 `[weekStart, weekEnd]` 或当前月 `[monthStart, monthEnd]` 闭区间查询每日日报：

1. **本地即时加载（`loadLocal`）**：读取 `zentaoSubmission`（已提交工时）及可选的 `zentaoPendingDraft`（未提交草稿），结合 `zentaoRepoMapping` 立即构建每日日报列表；月报模式下同步关联当月内已生成的 `weeklyReport` 作为参考。
2. **禅道远端同步（`fetch`）**：若已配置禅道账号，并发拉取 `myTasks()`、`finishedTasks()` 与 `myEstimates(since: periodStart, taskIDs: ...)`，与本地记录按任务 ID、工时及工作内容归一化去重，合并保留本地加班标记 `isOvertime` 并补齐项目名称与任务标题。
3. **草稿纳入控制**：可通过 `report.includeDrafts`（页内「含草稿」勾选框或设置页开关）随时控制是否把禅道日志页的未提交草稿纳入周报/月报汇总。

## 报告生成与风格（`WeeklyReportGenerator`）

- **三种报告风格（`WeeklyReportStyle`）**：
  - `.standard`（**标准周报**）：周报输出「本周完成工作 / 工时统计 / 问题与风险 / 下周工作计划」，月报输出「本月重点成果 / 本月工时统计 / 问题与风险 / 下月工作计划」。
  - `.byProject`（**按项目汇总**）：按禅道项目分小节汇报成果并统计项目工时。
  - `.concise`（**精简要点**）：紧凑的编号要点列表与简明工时结论，适合直接粘贴发送到飞书或钉钉群。
- **AI 生成与本地兜底**：
  - 配置了 `agy` 或 `codex` 时，调用 `AIRunner.run`（JSON Schema 要求返回 `title` 与 `content`）跨日/跨周合并同类工作并提炼业务产出；生成月报时还会将当月已写周报作为上下文传入 `{{weeklyReports}}`。
  - 未配置 AI 或 CLI 执行失败时，自动降级为 `fallbackReport` 按项目分组、拆行去重生成结构化 Markdown 报告。
- **自定义提示词占位符**：
  - 周报：`{{weekRange}}`、`{{totalHours}}`、`{{styleInstruction}}`、`{{dailyLogs}}`、`{{extraNotes}}`
  - 月报：`{{monthRange}}`、`{{totalHours}}`、`{{styleInstruction}}`、`{{dailyLogs}}`、`{{weeklyReports}}`、`{{extraNotes}}`

## 持久化与设置键（`ReportKeys`）

- **数据库表**：
  - `weeklyReport`（迁移 `report.v1`，主键 `weekStart` `yyyy-MM-dd`）
  - `monthlyReport`（迁移 `report.v2`，主键 `monthKey` `yyyy-MM`）
- **设置键**：
  - `report.lastPeriodKind`（默认 `.weekly`，用于未锁定模式）
  - `report.style`（默认 `.standard`）
  - `report.includeDrafts`（默认 `true`）
  - `report.includeHours`（默认 `true`）
  - `report.prompt`（默认 `WeeklyReportGenerator.defaultPrompt`）
  - `report.monthlyPrompt`（默认 `WeeklyReportGenerator.defaultMonthlyPrompt`）
