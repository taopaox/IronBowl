# 数据与存储

IronBowl 主工作台与独立版万年历共用同一个本地 SQLite 数据库文件，并通过 `DistributedNotificationCenter` 在两个进程之间实时同步设置变更和节假日标记。

## 存储位置（`AppPaths`）

定义于 [`AppDatabase.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Core/AppDatabase.swift)：

| 路径 | 说明 |
| :--- | :--- |
| `~/Library/Application Support/IronBowl/` | 应用支持根目录（`AppPaths.supportDirectory`） |
| `~/Library/Application Support/IronBowl/ironbowl.sqlite` | 共享 SQLite 数据库（WAL 模式，`AppPaths.databaseURL`） |
| `~/Library/Application Support/IronBowl/logs/` | 日志目录（`AppPaths.logsDirectory`） |
| `~/Library/Application Support/IronBowl/logs/zentao.log` | 禅道 HTTP 请求/响应调试日志（不含密码，超过 2MB 自动清空轮转） |
| `~/Library/Application Support/IronBowl/ai-logos/` | AI 目录插件上传/抓取的本地 PNG Logo 与远程图标缓存（`AILogoStore`） |
| `~/Library/Application Support/IronBowl/user-avatars/` | 用户自定义左下角头像/Logo 归一化 PNG 文件（`AppPaths.userAvatarsDirectory`、`UserProfileStore`） |
| `~/Library/Application Support/IronBowl/backups/` | 一键恢复备份前自动留存的安全库快照 `pre-restore-*.sqlite`（保留最近 5 份，`DataBackupService`） |

## 数据库与迁移（`AppDatabase`）

`AppDatabase` 使用 GRDB `DatabasePool` 打开数据库，启用 `config.foreignKeysEnabled = true`，并在启动时按序执行 `coreMigrations + pluginMigrations`。

### 核心迁移（`core.v1` ~ `core.v11`）

| 迁移版本 | 表名 | 主键 | 字段 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| `core.v1` | `setting` | `key` (TEXT) | `value` (TEXT, NOT NULL) | 强类型设置表，所有 `SettingKey<Value>` 以 JSON 包装存入 |
| `core.v1` | `holiday` | `date` (TEXT) | `isOffDay` (BOOLEAN), `name` (TEXT), `source` (TEXT) | 联网拉取的法定节假日与调休安排 |
| `core.v1` | `holidayOverride` | `date` (TEXT) | `isOffDay` (BOOLEAN), `note` (TEXT) | 用户手动标记某天放假或补班（优先级高于 `holiday`） |
| `core.v2` | `scheduledTask` | `id` (TEXT) | `name`, `actionID`, `isEnabled`, `scheduleJSON`, `misfirePolicy`, `notifyPolicy`, `notifyStyle`, `parametersJSON`, `nextRunAt`, `lastRunAt`, `lastFiredSlot`, `lastStatus`, `lastSummary`, `createdAt`, `updatedAt` | 定时任务定义、参数及调度状态 |
| `core.v2` | `scheduledTaskRun` | `id` (自增 INT) | `taskID` (索引), `taskName`, `actionID`, `trigger`, `status`, `startedAt` (索引), `finishedAt`, `summary`, `detail` | 定时任务历史执行记录 |
| `core.v3` | `attendanceClockIn` | `date` (TEXT, `yyyy-MM-dd`) | `clockIn` (DATETIME), `source` (TEXT，目前为 `dingtalk`), `fetchedAt` (DATETIME) | 每天的上班打卡时间，供 `WorkCalendar` 按弹性规则折算下班时间 |
| `core.v4` | `dailyOvertime` | `date` (TEXT, `yyyy-MM-dd`) | `hours` (DOUBLE), `updatedAt` (DATETIME) | 按天记录的计划加班小时数，供 `WorkCalendar` 顺延实际下班时间与 `ZentaoLogPlugin` 统计目标工时（建表时自动迁入既有 `zentaoDailyOvertime` 数据） |
| `core.v5` | `chatThread` | `id` (TEXT) | `title`, `providerKind`, `model`（`core.v6` 新增）, `workspacePath`, `permissionMode`, `remoteSessionID`, `isPinned`, `createdAt`, `updatedAt`（索引） | 首页「今天」多对话工作台的对话线程、绑定工作目录、模型选择与 CLI 会话 ID |
| `core.v5` | `chatMessage` | `id` (TEXT) | `threadID`（外键级联删除+索引）, `role`, `content`, `status`, `providerKind`, `modelName`, `durationSeconds`, `usageJSON`, `activitiesJSON`, `rawEventsJSON`, `cardsJSON`, `errorMessage`, `createdAt`（索引）, `updatedAt` | 对话消息正文、命令/工具执行明细、原始 JSONL 事件与插入的功能卡片快照 |
| `core.v6` | `chatThread` | `id` (TEXT) | 新增列 `model` (TEXT, NOT NULL, DEFAULT `''`) | 按对话持久化各自选用的模型 ID |
| `core.v7` | `reminderHistory` | `id` (自增 INT) | `reminderID`（索引）, `title`, `message`, `systemImage`, `source`（索引）, `style`, `deliveryStatus`, `deliveryDetail`, `isRead`（索引）, `readAt`, `handledActionTitle`, `handledAt`, `targetPluginID`, `targetSettingsPage`, `createdAt`（索引） | `ReminderCenter` 触发的历史桌面/系统提醒记录、投递结果、已读与操作状态 |
| `core.v8` | `todoItem` | `id` (TEXT) | `title`, `notes`, `dueDate`（索引）, `remindAt`, `remindedAt`, `priority`, `estimatedHours`, `isCompleted`（索引）, `completedAt`, `loggedDate`, `zentaoObjectType`, `zentaoObjectID`, `createdAt`, `updatedAt`（索引） | 跨工作台、万年历与禅道日报共享的待办与备忘数据 |
| `core.v9` | `scratchpadNote` | `id` (TEXT) | `title`, `content`, `colorTag`, `isPinned`, `createdAt`, `updatedAt`（索引） | 随手便签与剪贴板暂存板内容 |
| `core.v10` | `attendanceDailyRecord` | `date` (TEXT, `yyyy-MM-dd`) | `clockIn`, `clockOut`, `onDutyResult`, `offDutyResult`, `source`, `fetchedAt` | 每日完整上下班打卡与异常状态（自动迁入既有 `attendanceClockIn` 记录） |
| `core.v11` | `clipboardHistory` | `id` (TEXT) | `content`, `contentHash`（索引）, `kind`, `sourceApp`, `charCount`, `copyCount`, `isSnippet`（索引）, `snippetTitle`, `copiedAt`（索引） | 剪贴板历史流与永久保留的常用片段（Snippets） |

### 禅道日志插件迁移（`LogMigrations`）

定义于 [`LogSettings.swift`](../../Packages/ZentaoLogPlugin/Sources/ZentaoLogPlugin/Store/LogSettings.swift)：

| 迁移版本 | 表名 | 主键 | 主要字段 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| `zentao.v1` | `zentaoRepoMapping` | `repoPath` (TEXT) | `projectID`, `projectName`, `excluded`, `sendDiff` | Git 仓库与禅道项目映射、排除及 diff 开关 |
| `zentao.v1` | `zentaoSubmission` | `id` (自增 INT) | `date` (索引), `taskID`, `hours`, `left`, `work`, `isOvertime`, `submittedAt` | 本地已成功提交到禅道的工时记录 |
| `zentao.v1` | `zentaoLastTask` | `repoPath` (TEXT) | `taskID` | 每个仓库上次提交使用的禅道任务 ID |
| `zentao.v2` | `zentaoPendingDraft` | `date` (TEXT) | `payload` (JSON `[DraftEntry]`), `updatedAt` | 按天持久化的未提交待修改草稿 |
| `zentao.v3` | `zentaoDailyOvertime` | `date` (TEXT) | `hours` (DOUBLE), `updatedAt` | 历史按天加班表（保留迁移号兼容旧库，数据已由 `core.v4` 迁移至核心表 `dailyOvertime`） |

### 周报月报插件迁移（`ReportMigrations`）

定义于 [`ReportStore.swift`](../../Packages/ReportPlugin/Sources/ReportPlugin/Store/ReportStore.swift)：

| 迁移版本 | 表名 | 主键 | 主要字段 | 用途 |
| :--- | :--- | :--- | :--- | :--- |
| `report.v1` | `weeklyReport` | `weekStart` (TEXT) | `weekEnd`, `title`, `content`, `extraNotes`, `style`, `providerName`, `totalHours`, `generatedAt`, `updatedAt`（索引） | 按周（周一日期 `yyyy-MM-dd`）持久化已生成或手动编辑的周报内容 |
| `report.v2` | `monthlyReport` | `monthKey` (TEXT) | `periodStart`, `periodEnd`, `title`, `content`, `extraNotes`, `style`, `providerName`, `totalHours`, `generatedAt`, `updatedAt`（索引） | 按自然月（`yyyy-MM`）持久化已生成或手动编辑的月报内容 |
| `report.v3` | `reviewReport` | `periodKey` (TEXT) | `scopeKind`, `periodStart`, `periodEnd`, `title`, `content`, `extraNotes`, `style`, `providerName`, `totalHours`, `overtimeHours`, `commitCount`, `generatedAt`, `updatedAt`（索引） | 按季度/半年度/全年持久化述职总结报告 |

> 独立版万年历（`Apps/Calendar`）在启动时只传入 `CalendarPlugin.migrations`（当前为空），若库中已有其他插件的数据表也不会冲突；若首次由独立版万年历建库，之后主应用打开时会补跑新增的插件迁移。

## 设置存储与跨进程同步（`SettingsStore`）

定义于 [`SettingsStore.swift`](../../Packages/IronBowlKit/Sources/IronBowlKit/Core/SettingsStore.swift)：

- **强类型键**：`SettingKey<Value: Codable & Sendable>(_ name: String, default: Value)`。
- **JSON 包装**：写入时使用内部 `Wrapper(v: newValue)` 编码，使得顶层 `String`、`Int`、`Double`、`Bool`、`Optional` 也能统一合法序列化为 JSON。
- **去重防循环**：写入 `settings[key] = newValue` 时若 JSON 字符串与内存缓存一致，则直接返回不写库也不触发通知，避免 SwiftUI `Binding` 回写导致死循环。
- **跨进程通知**：
  - `SettingsStore` 写入数据库后会通过 `DistributedNotificationCenter` 发送 `com.taopaox.ironbowl.settingsDidChange`，附带 `"\(pid)|\(database.path)"`；另一进程收到且匹配同一数据库路径时自动 `reload()` 并回调 `onExternalChange`（同步外观与字号）。
  - `WorkCalendar` 修改节假日缓存或手动标记后会发送 `com.taopaox.ironbowl.holidaysDidChange`，另一进程收到后自动重载节假日表。

## 全部 `SettingKey` 清单

| 命名空间 | 键名 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `AppKeys` | `app.appearance` | `.system` | 主题模式（`system` / `light` / `dark`） |
| `AppKeys` | `app.fontScale` | `1.0` | 全局字体缩放档位（`0.9...1.4`） |
| `AppKeys` | `app.enabledPlugins` | `nil` | 已启用插件 ID 列表（`nil` 表示全启用） |
| `AppKeys` | `app.knownPlugins` | `[]` | 已知插件 ID 列表（用于升级自动发现新插件） |
| `AppKeys` | `app.menuBarItems` | `["zentao.status"]` | 菜单栏图标后拼接显示的条目及顺序 |
| `AppKeys` | `app.dockMode` | `.whenWindowOpen` | 程序坞图标策略（`always` / `whenWindowOpen` / `never`） |
| `AppKeys` | `app.lastPlugin` | `"home"` | 上次停留在主窗口的页面 ID |
| `UserProfileKeys` | `user.displayName` / `user.slogan` / `user.avatarFilename` | `""` / `""` / `nil` | 左下角自定义显示姓名、个人标语与自定义头像 PNG 文件名 |
| `WorkCalendar` | `work.weekdays` | `[2,3,4,5,6]` | 每周工作日（周一至周五） |
| `WorkCalendar` | `work.start` / `work.end` | `"09:00"` / `"18:00"` | 上下班时间 |
| `WorkCalendar` | `work.lunchMinutes` | `60` | 午休分钟数 |
| `WorkCalendar` | `holiday.source` / `holiday.frequency` | `.holidayCNjsDelivr` / `.yearly` | 节假日数据源与更新频率 |
| `WorkCalendar` | `holiday.lastFetch` | `nil` | 上次成功拉取节假日的时间 |
| `AIProviderStore` | `ai.providers` / `ai.default` | `[agy, codex]` / `.agy` | AI CLI 配置与默认提供者 |
| `ChatKeys` | `chat.defaultWorkspace` / `chat.detailLevel` / `chat.sidebarCollapsed` / `chat.lastThreadID` / `chat.lastModelByProvider` | `""` / `.all` / `false` / `nil` / `[:]` | 首页对话默认工作目录、输出详略级别、对话栏折叠、上次选中对话 ID 及各提供商记忆模型 |
| `WebKeys` | `web.tombstone.enabled` | `true` | 是否开启后台网页墓碑休眠 |
| `WebKeys` | `web.tombstone.idleMinutes` | `15` | 后台闲置休眠分钟数（0 表示不按时长） |
| `WebKeys` | `web.tombstone.maxLiveCount` | `4` | 最多同时保活网页数（0 表示不限） |
| `SchedulerKeys` | `scheduler.seededIDs` | `[]` | 已初始化写入过的内置定时任务 ID 列表（防用户删除后重建） |
| `LogKeys` | `zentao.*` / `git.*` / `scan.*` / `log.*` / `reminder.*` / `zentao.watch.*` | 见 [禅道日志文档](../plugins/zentao-log.md) | 禅道账号、Git 扫描、AI 提示词、工时提醒与新指派 Bug/任务巡检配置 |
| `LogKeys.quickLogShortcut` | `log.quickLogShortcut` | `true` | 启用日报插件的全局快捷记日志组合键 ⌃⌥⌘L |
| `ReportKeys` | `report.*` | 见 [周报月报文档](../plugins/report.md) | 周报/月报提示词、风格、草稿与工时开关及上次周期模式 |
| `CalendarKeys` | `calendar.*` / `weather.*` | 见 [万年历文档](../plugins/calendar.md) | 周起始日、天气源、城市、菜单栏日历与弹层样式 |
| `FeishuKeys` | `feishu.*` | 见 [飞书文档](../plugins/feishu.md) | 飞书主页、固定网页列表与上次打开页 |
| `AIWebKeys` | `aiweb.apps` / `aiweb.activeAppID` | `nil` / `nil` | AI 目录应用列表与当前选中 AI |
| `ClipboardKeys` | `clipboard.enabled` / `clipboard.maxCount` | `true` / `200` | 剪贴板历史监听开关与非片段历史保留条数上限 |
| `WorkspaceKeys` | `workspace.*` | 见 [代码仓库文档](../plugins/workspace.md) | 默认外部编辑器/终端、收藏置顶仓库与额外纳管仓库路径 |
