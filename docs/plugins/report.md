# 周报与月报插件（`ReportPlugin` & `MonthlyReportPlugin`）

`Packages/ReportPlugin` 同时提供三个插件——**周报**（`ReportPlugin`，ID：`report`）、**月报**（`MonthlyReportPlugin`，ID：`report.monthly`）与 **牛马账本**（`WorkLedgerPlugin`，ID：`report.stats`），在主窗口左侧栏通过 `sidebarSection = "汇报"` 与 `ZentaoLogPlugin`（「日报」）共同归入「汇报」分组。周报与月报复用同一套日报查询与生成底座，分别按周（周一至周日）或按自然月（1 日至月末）汇总每日工作日报并生成结构化报告；牛马账本则按月/年汇总工时、加班、钉钉打卡作息与项目投入占比。

## 模块组成

| 文件 | 核心符号 | 职责 |
| :--- | :--- | :--- |
| `ReportPlugin.swift` | `ReportPlugin`, `MonthlyReportPlugin`, `WorkLedgerPlugin` | 三个独立侧边栏插件入口：周报（ID：`report`，锁定 `.weekly`，含「Tita 对接」设置页）、月报（ID：`report.monthly`，锁定 `.monthly`）与牛马账本（ID：`report.stats`） |
| `WorkLedgerModel.swift` | `WorkLedgerModel`, `WorkLedgerSummary`, `LedgerPeriodMode`, `LedgerDayStat`, `LedgerAnomalyDay`, `LedgerMonthStat`, `LedgerProjectStat` | 按月/年汇总禅道工时、本地加班记录、钉钉上下班打卡与真实在岗时长、缺卡/迟到早退核对及项目工时占比 |
| `Views/WorkLedgerView.swift` | `WorkLedgerView` | 「牛马账本」工时热力日历、年度柱状分布、在岗 vs 填报时长对比、考勤异常核对与项目投入占比看板（支持一键同步区间钉钉考勤） |
| `ReportChatHandler.swift` | `ReportChatHandler`, `ReportChatIntent` | 识别首页对话中的生成/查看周报或月报指令（过滤代码/调试类提问） |
| `Views/ReportChatCard.swift` | `ReportChatCard` | 在首页聊天流内直接展示并操作的周报/月报卡片（Markdown 预览、展开、重新生成、复制与打开 Tita） |
| `ReportModel.swift` | `WeeklyReportModel` | `@Observable` 业务状态：支持 `lockedPeriodKind` 锁定周/月模式、上下周与上下月切换、调用 `ZentaoDailyLogService` 查区间日报、生成/编辑/自动保存、历史列表、复制/导出 Markdown 与 Tita 状态查询/草稿保存/提交 |
| `Model/WeekRange.swift` | `WeekRange` | 按中国工作周（周一至周日）与 ISO 周历计算起止日期、周次标题、上下周偏移及「本周 / 上周」标签 |
| `Model/MonthRange.swift` | `MonthRange`, `MonthWeekSlice` | 按自然月（1 日至月末）计算起止日期、周分片（`weeks`）、上下月偏移及「本月 / 上月」标签 |
| `Model/ReportMarkdown.swift` | `ReportMarkdownBlock`, `ReportMarkdown` | 面向中文标点相邻 `**加粗**` 与多级嵌套列表的轻量 Markdown 块级/行内解析器 |
| `Store/ReportStore.swift` | `ReportPeriodKind`, `WeeklyReportStyle`, `ReportKeys`, `WeeklyReportRecord`, `MonthlyReportRecord`, `ReportMigrations`, `ReportStore` | 设置键（含 Tita 配置）、拆分迁移 `ReportMigrations.weekly`（`report.v1` / `weeklyReport`）与 `ReportMigrations.monthly`（`report.v2` / `monthlyReport`）及读写操作 |
| `Generator/WeeklyReportGenerator.swift` | `DailyReportDay`, `WeeklyReportInput`, `MonthlyReportInput`, `WeeklyReportOutput`, `WeeklyReportGenerator` | 周报/月报提示词模板渲染、只读 JSON Schema AI 生成与 4 种风格的规则兜底汇总（含 `tita` 模板风格） |
| `Tita/TitaModels.swift` | `TitaSummaryType`, `TitaSubmitState`, `TitaMood`, `TitaAccountInfo`, `TitaPeriodStatus`, `TitaTemplateSummary`, `TitaReportDetail`, `TitaEditableModule`, `TitaSearchFeedItem`, `TitaHistorySyncResult`, `TitaError` | Tita 周报（`26`）/月报（`27`）接口数据模型、历史列表模型与状态枚举 |
| `Tita/TitaHelpers.swift` | `TitaPeriodCode`, `TitaCredentialParser`, `TitaBSGlobalParser`, `TitaRichTextConverter`, `TitaContentMapper`, `TitaSubmitPayloadBuilder`, `TitaProseMirrorParser` | Tita 周期正反向编码（`YYYY-MM-WW` / `YYYY-MM-01` ↔ `WeekRange` / `MonthRange`）、cURL/Cookie 解析、`BSGlobal` 识别、ProseMirror `EditorState` JSON 与 Markdown 互转、4 模块内容映射与提交请求体拼装 |
| `Tita/TitaClient.swift` | `TitaClient`, `TitaLog` | Tita 直连 HTTP 客户端（Cookie 鉴权、会话复用与 `URLSession` 长连接、TLS 握手/建连瞬断自动重试、身份探测、模板拉取、历史分页拉取 `summary/search`、草稿更新、正式提交、删除 `summary/delete` 与回查）及脱敏接口日志 `tita.log` |
| `Tita/TitaHistorySyncService.swift` | `TitaHistorySyncService` | 自动分页拉取 Tita 个人全部历史周报/月报并安全合并写入本地 `weeklyReport` / `monthlyReport`（默认保护本地已编辑内容） |
| `Views/ReportView.swift` | `ReportView` | 双页活页手账工作区（`JournalSpreadShell`）：顶栏展示章节实心身份胶囊（「周报」松绿 / 「月报」靛蓝）与高对比状态胶囊（「本周未写 / 本月未写 / Tita 未交 / 本周已写」）、历史弹层、刷新与 AI 选择器，右缘提供「日报 / 周报 / 月报 / 历史」彩签；左页展示周期撕历、三联汇总、周/月筛选条及联动日报荧光笔重点的每日摘录（支持 `+ 引用` 插入正文）；右页顶部贯通状态色带，内置 `JournalStatusBanner` 醒目横幅、默认展开的大尺寸黄色便利贴「补充说明」（`JournalStickyNote`，支持按需收起）、可点击 Tita 状态橡皮印章、单行聚焦工具栏与手账排印正文/Markdown 编辑区 |
| `Views/ReportSettingsView.swift` | `ReportSettingsView` | 按 `periodKind` 分别呈现「周报 → 周报生成」与「月报 → 月报生成」设置页：默认风格、草稿/工时开关、提示词编辑与「Tita 对接」跳转入口 |
| `Views/TitaViews.swift` | `TitaAccountSettings`, `TitaWebLoginSheet`, `TitaSubmitSheet` | Tita 对接设置页（内置 `WKWebView` 登录提取 Cookie / 导入 cURL 与请求头 / 模板配置 / 一键同步全部历史周报与月报）与推送预览/存草稿/确认提交弹窗 |

## 周期日报查询机制

`WeeklyReportModel` 通过 `ZentaoLogPlugin` 暴露的 `ZentaoDailyLogService` 按当前周 `[weekStart, weekEnd]` 或当前月 `[monthStart, monthEnd]` 闭区间查询每日日报：

1. **本地即时加载（`loadLocal`）**：读取 `zentaoSubmission`（已提交工时）及可选的 `zentaoPendingDraft`（未提交草稿），结合 `zentaoRepoMapping` 立即构建每日日报列表；月报模式下同步关联当月内已生成的 `weeklyReport` 作为参考。
2. **禅道远端同步（`fetch`）**：若已配置禅道账号，并发拉取 `myTasks()`、`finishedTasks()` 与 `myEstimates(since: periodStart, taskIDs: ...)`，与本地记录按任务 ID、工时及工作内容归一化去重，合并保留本地加班标记 `isOvertime` 并补齐项目名称与任务标题。
3. **草稿纳入控制**：可通过 `report.includeDrafts`（页内「含草稿」勾选框或设置页开关）随时控制是否把禅道日志页的未提交草稿纳入周报/月报汇总。

## 报告生成与风格（`WeeklyReportGenerator`）

- **四种报告风格（`WeeklyReportStyle`）**：
  - `.standard`（**标准周报**）：周报输出「本周完成工作 / 工时统计 / 问题与风险 / 下周工作计划」，月报输出「本月重点成果 / 本月工时统计 / 问题与风险 / 下月工作计划」。
  - `.byProject`（**按项目汇总**）：按禅道项目分小节汇报成果并统计项目工时。
  - `.concise`（**精简要点**）：紧凑的编号要点列表与简明工时结论，适合直接粘贴发送到飞书或钉钉群。
  - `.tita`（**Tita 模板**）：直接输出「亮点与成功经验 / 问题与不足 / 改进思考与行动 / 下一步工作计划」四段结构，与 Tita 周报/月报模板一一对应。
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
  - `report.tita.baseURL`（默认 `"https://www.tita.net"`）
  - `report.tita.cookie`（Tita 会话 Cookie，默认空）
  - `report.tita.tenantID` / `report.tita.userID` / `report.tita.userName`（验证登录态后自动从 `BSGlobal` 与 `summary/status` 填充）
  - `report.tita.weeklyTemplateID`（默认 `1006`） / `report.tita.monthlyTemplateID`（默认 `1007`）
  - `report.tita.defaultMood`（默认 `0` 不选）

## Tita 周报/月报直连对接

在「设置 → 周报 → Tita 对接」或周报/月报工具栏点击「推送 Tita」即可对接：

1. **凭证获取（二选一）**：
   - **内置网页登录提取**：`TitaWebLoginSheet` 使用共享 `WKWebsiteDataStore.default()` 打开 `https://www.tita.net/login/#/login`，登录跳转后自动提取 `tita.net` Cookie 并校验身份、自动探测企业模板 ID。
   - **导入 Cookie / Copy as cURL**：`TitaCredentialParser` 支持直接粘贴 Chrome DevTools 复制的 `curl` 命令、`Cookie:` 请求头或纯 Cookie 字符串，并自动识别 URL 中的 `tenantId` 与 `userId`。
2. **周期映射与富文本拆分**：
   - `TitaPeriodCode` 按 Tita 规则将周报编码为周一所在自然月的第 `WW` 周（`YYYY-MM-WW`）、月报编码为 `YYYY-MM-01`。
   - `TitaContentMapper` 将本地生成的 Markdown 报告自动映射为 Tita 的 4 个富文本模块，`TitaRichTextConverter` 转为 Tita ProseMirror `EditorState` JSON（`{"doc": ..., "selection": ...}`）与纯文本（上限 10,000 字）。
3. **草稿保存与确认提交**：
   - 查询接口：`GET summary/status`、`GET summary/selectTemplates`、`POST summary/detail`（解析状态与详情时自动忽略非正 `tempId` / `summaryTemplateId`，并在初始化编辑面板与创建草稿前对齐 `summary/selectTemplates` 的有效模板 ID，模板失效时自动回退重试）；
   - 初始化与保存草稿：`POST summary/create/{dailyDate}/{reportType}/{templateId}`、`POST summary/mood/update/{feedId}/{moduleId}/{mood}`、`POST summary/richtext/update`、`POST summary/delete/{feedId}`；
   - 正式提交/更新：提交前重新拉取详情保留既有 OKR/附件/`@ta查看` 等模块数据，调用 `POST summary/checkchange/{feedId}` 与 `POST summary/submit/{feedId}/1`（需经二次确认弹窗）；`WeeklyReportModel` 自动复用同一会话的 `TitaClient`（保持 `URLSession` TLS 长连接），对 TLS 握手/建连瞬断与幂等请求自动退避重试，所有脱敏请求摘要及传输层错误均写入 `~/Library/Application Support/IronBowl/logs/tita.log`。
4. **历史周报与月报同步**：
   - 在「设置 → 周报 → Tita 对接」点击「一键同步全部历史」，或在周报/月报页面历史弹层点击「同步 Tita」。
   - `TitaHistorySyncService` 调用 `POST summary/search`（`relation = 1`、`startTime/endTime = ""`）自动翻页拉取全部历史周报与月报，`TitaProseMirrorParser` 将 `dailyContent[].richContent` 的 ProseMirror JSON（兼容旧版 HTML）转换为 Markdown，`TitaPeriodCode.weekRange(fromSummaryDate:)` / `monthRange(fromSummaryDate:)` 反向映射为 `WeekRange` / `MonthRange`，合并写入 `weeklyReport` / `monthlyReport`（`providerName = "Tita 同步"`）。
   - 冲突保护：默认跳过已有非空且非 `"Tita 同步"` 来源的本地报告，仅补齐缺失周期或刷新先前由 Tita 同步的记录；设置页可选开启「覆盖本地已编辑的报告」。

## 定时自动生成与 Tita 未交提醒

`ReportPlugin` 与 `MonthlyReportPlugin` 在启动时分别向 `context.scheduler` 注册 `report.autoGenerateWeekly` 与 `report.autoGenerateMonthly` 定时动作，并在首次安装时写入内置默认任务 `builtin.report.weeklyAutoGenerate`：

- **默认调度**：每周五 `17:30`（`MisfirePolicy.runIfMissedToday`），汇总本周每日日报（无日报时自动 `.skipped` 跳过）。
- **防覆盖保护（`overwriteExisting`）**：默认 `false`，若本周已存在非空周报则保留既有内容不覆盖；开启后重新汇总生成。
- **Tita 未交提醒（`remindIfTitaUnsubmitted`）**：默认 `true`，若已配置 Tita 且检测到当前周期尚未正式提交，则通过 `ReminderCenter` 弹出 `report.tita.unsubmitted.*` 提醒，支持一键跳转周报/月报页预览推送。
