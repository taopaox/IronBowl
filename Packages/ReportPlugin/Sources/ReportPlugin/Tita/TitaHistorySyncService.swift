import Foundation
import IronBowlKit

/// 将 Tita 历史周报与月报同步写入本地 SQLite（`weeklyReport` / `monthlyReport`）。
public nonisolated enum TitaHistorySyncService {
    public static let providerName = "Tita 同步"

    /// 使用已保存的 `report.tita.*` 设置执行一次完整同步。
    @discardableResult
    public static func syncUsingSavedSettings(
        database: AppDatabase,
        settings: SettingsStore,
        scope: TitaSyncScope = .all,
        overwriteLocalEdits: Bool = false
    ) async throws -> TitaHistorySyncResult {
        let baseURL = await MainActor.run { settings[ReportKeys.titaBaseURL] }
        let cookie = await MainActor.run { settings[ReportKeys.titaCookie] }
        var tenantID = await MainActor.run { settings[ReportKeys.titaTenantID] }
        var userID = await MainActor.run { settings[ReportKeys.titaUserID] }

        let client = try TitaClient(
            baseURL: baseURL,
            cookie: cookie,
            tenantID: tenantID,
            userID: userID
        )

        if tenantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let info = try await client.verifySession()
            tenantID = info.tenantID
            userID = info.userID
            await MainActor.run {
                settings[ReportKeys.titaTenantID] = info.tenantID
                settings[ReportKeys.titaUserID] = info.userID
                if !info.userName.isEmpty {
                    settings[ReportKeys.titaUserName] = info.userName
                }
            }
        }

        return try await sync(
            client: client,
            database: database,
            scope: scope,
            overwriteLocalEdits: overwriteLocalEdits
        )
    }

    /// 通过指定 `TitaClient` 拉取远端历史记录并合并到本地数据库。
    @discardableResult
    public static func sync(
        client: TitaClient,
        database: AppDatabase,
        scope: TitaSyncScope = .all,
        overwriteLocalEdits: Bool = false
    ) async throws -> TitaHistorySyncResult {
        let store = ReportStore(db: database)
        var weeklyStats = TitaPeriodSyncStats()
        var monthlyStats = TitaPeriodSyncStats()

        if scope == .weekly || scope == .all {
            let feeds = try await client.fetchAllSummaries(summaryType: .weekly)
            weeklyStats = mergeWeeklyFeeds(feeds, store: store, overwriteLocalEdits: overwriteLocalEdits)
        }
        if scope == .monthly || scope == .all {
            let feeds = try await client.fetchAllSummaries(summaryType: .monthly)
            monthlyStats = mergeMonthlyFeeds(feeds, store: store, overwriteLocalEdits: overwriteLocalEdits)
        }

        return TitaHistorySyncResult(scope: scope, weekly: weeklyStats, monthly: monthlyStats)
    }

    static func mergeWeeklyFeeds(
        _ feeds: [TitaSearchFeedItem],
        store: ReportStore,
        overwriteLocalEdits: Bool = false
    ) -> TitaPeriodSyncStats {
        var stats = TitaPeriodSyncStats(fetched: feeds.count)

        for feed in feeds where feed.reportType == .weekly {
            guard let week = TitaPeriodCode.weekRange(fromSummaryDate: feed.dailyDate) else {
                stats.ignoredEmpty += 1
                continue
            }
            let markdown = TitaProseMirrorParser.renderFeedMarkdown(feed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                stats.ignoredEmpty += 1
                continue
            }

            let existing = store.report(forWeekStart: week.startDateString)
            if let existing,
               !existing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               existing.providerName != providerName,
               !overwriteLocalEdits {
                stats.skipped += 1
                continue
            }

            let title = feed.name.isEmpty ? WeeklyReportGenerator.defaultTitle(for: week) : feed.name
            let timestamp = TitaPeriodCode.parseSubmitDate(feed.submitDate) ?? week.endDate
            let record = WeeklyReportRecord(
                weekStart: week.startDateString,
                weekEnd: week.endDateString,
                title: title,
                content: markdown,
                extraNotes: existing?.extraNotes ?? "",
                style: WeeklyReportStyle.tita.rawValue,
                providerName: providerName,
                totalHours: existing?.totalHours ?? 0,
                generatedAt: existing?.generatedAt ?? timestamp,
                updatedAt: timestamp
            )
            store.save(record)
            if existing == nil {
                stats.inserted += 1
            } else {
                stats.updated += 1
            }
        }
        return stats
    }

    static func mergeMonthlyFeeds(
        _ feeds: [TitaSearchFeedItem],
        store: ReportStore,
        overwriteLocalEdits: Bool = false
    ) -> TitaPeriodSyncStats {
        var stats = TitaPeriodSyncStats(fetched: feeds.count)

        for feed in feeds where feed.reportType == .monthly {
            guard let month = TitaPeriodCode.monthRange(fromSummaryDate: feed.dailyDate) else {
                stats.ignoredEmpty += 1
                continue
            }
            let markdown = TitaProseMirrorParser.renderFeedMarkdown(feed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else {
                stats.ignoredEmpty += 1
                continue
            }

            let existing = store.monthlyReport(forMonthKey: month.monthKey)
            if let existing,
               !existing.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               existing.providerName != providerName,
               !overwriteLocalEdits {
                stats.skipped += 1
                continue
            }

            let title = feed.name.isEmpty ? WeeklyReportGenerator.defaultTitle(for: month) : feed.name
            let timestamp = TitaPeriodCode.parseSubmitDate(feed.submitDate) ?? month.endDate
            let record = MonthlyReportRecord(
                monthKey: month.monthKey,
                periodStart: month.startDateString,
                periodEnd: month.endDateString,
                title: title,
                content: markdown,
                extraNotes: existing?.extraNotes ?? "",
                style: WeeklyReportStyle.tita.rawValue,
                providerName: providerName,
                totalHours: existing?.totalHours ?? 0,
                generatedAt: existing?.generatedAt ?? timestamp,
                updatedAt: timestamp
            )
            store.saveMonthly(record)
            if existing == nil {
                stats.inserted += 1
            } else {
                stats.updated += 1
            }
        }
        return stats
    }
}
