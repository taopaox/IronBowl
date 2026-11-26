import Foundation
import Observation
import WebKit

public enum WebKeys {
    /// 是否启用后台网页墓碑休眠。
    public static let tombstoneEnabled = SettingKey<Bool>("web.tombstone.enabled", default: true)
    /// 后台闲置多少分钟后自动休眠（0 表示不按时间休眠，仅按数量上限）。
    public static let tombstoneIdleMinutes = SettingKey<Int>("web.tombstone.idleMinutes", default: 15)
    /// 最多同时保活的网页数（0 表示不限数量）。
    public static let tombstoneMaxLiveCount = SettingKey<Int>("web.tombstone.maxLiveCount", default: 4)
}

/// 全应用共享的网页会话与墓碑管理器。所有内嵌网页的插件统一通过它调度内存回收。
@Observable
public final class WebSessionManager {
    public let settings: SettingsStore
    public private(set) var sessionIDs: [String] = []

    @ObservationIgnored private var sessions: [String: WebSession] = [:]
    @ObservationIgnored private var displayTokens: [String: UUID] = [:]
    @ObservationIgnored private var sweepTimer: Timer?
    @ObservationIgnored private let headlessForTesting: Bool

    public init(settings: SettingsStore, startTimer: Bool = true, headlessForTesting: Bool = false) {
        self.settings = settings
        self.headlessForTesting = headlessForTesting
        if startTimer {
            sweepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.sweep() }
                }
            }
            sweepTimer?.tolerance = 10
        }
    }

    // MARK: - 配置与统计

    public var tombstoneEnabled: Bool {
        get { settings[WebKeys.tombstoneEnabled] }
        set {
            settings[WebKeys.tombstoneEnabled] = newValue
            if newValue {
                Task { await sweep() }
            }
        }
    }

    public var idleMinutes: Int {
        get { settings[WebKeys.tombstoneIdleMinutes] }
        set {
            settings[WebKeys.tombstoneIdleMinutes] = max(0, newValue)
            Task { await sweep() }
        }
    }

    public var maxLiveCount: Int {
        get { settings[WebKeys.tombstoneMaxLiveCount] }
        set {
            settings[WebKeys.tombstoneMaxLiveCount] = max(0, newValue)
            Task { await enforceLiveLimit() }
        }
    }

    public var liveCount: Int {
        sessionIDs.compactMap { sessions[$0] }.filter { $0.state == .active }.count
    }

    public var tombstonedCount: Int {
        sessionIDs.compactMap { sessions[$0] }.filter { $0.state == .tombstoned }.count
    }

    /// 收集当前所有活跃 `WKWebView` 关联的 WebContent 渲染进程明细。
    public func activeWebProcessDescriptors() -> [TrackedProcessDescriptor] {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        typealias PIDGetter = @convention(c) (AnyObject, Selector) -> pid_t
        var descriptors: [TrackedProcessDescriptor] = []
        for id in sessionIDs {
            guard let session = sessions[id],
                  session.state == .active,
                  let webView = session.webView,
                  webView.responds(to: selector),
                  let imp = webView.method(for: selector) else { continue }
            let getter = unsafeBitCast(imp, to: PIDGetter.self)
            let pid = getter(webView, selector)
            guard pid > 0 else { continue }

            let customName = session.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pageTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if let customName, !customName.isEmpty {
                name = customName
            } else if !pageTitle.isEmpty {
                name = pageTitle
            } else {
                name = WebURL.cleanTitle(nil, fallbackURL: session.currentURL)
            }

            let rawHost = URL(string: session.currentURL)?.host
            let host = rawHost?.hasPrefix("www.") == true ? String(rawHost!.dropFirst(4)) : rawHost

            descriptors.append(
                TrackedProcessDescriptor(
                    pid: pid,
                    name: name,
                    detail: host,
                    kind: .webPage,
                    sessionID: session.id,
                    isVisible: session.isVisible,
                    neverSuspend: session.neverSuspend
                )
            )
        }
        return descriptors
    }

    /// 收集当前所有活跃 `WKWebView` 关联的 WebContent 渲染进程 PID。
    public func activeWebProcessPIDs() -> Set<pid_t> {
        Set(activeWebProcessDescriptors().map(\.pid))
    }

    // MARK: - 会话生命周期

    public func session(
        id: String,
        initialURL: String,
        blockedSchemes: Set<String> = [],
        neverSuspend: Bool = false,
        displayName: String? = nil
    ) -> WebSession {
        if let existing = sessions[id] {
            existing.neverSuspend = neverSuspend
            if let displayName {
                existing.displayName = displayName
            }
            return existing
        }
        let created = WebSession(
            id: id,
            initialURL: initialURL,
            blockedSchemes: blockedSchemes,
            neverSuspend: neverSuspend,
            displayName: displayName,
            startActive: true,
            headlessForTesting: headlessForTesting
        )
        sessions[id] = created
        sessionIDs.append(id)
        Task { await enforceLiveLimit() }
        return created
    }

    public func setDisplayName(_ name: String?, for id: String) {
        sessions[id]?.displayName = name
    }

    public func hasSession(id: String) -> Bool {
        sessionIDs.contains(id) && sessions[id] != nil
    }

    public func existingSession(id: String) -> WebSession? {
        _ = sessionIDs
        return sessions[id]
    }

    public func isTombstoned(id: String) -> Bool {
        _ = sessionIDs
        return sessions[id]?.isTombstoned ?? false
    }

    public func setNeverSuspend(_ value: Bool, for id: String) {
        sessions[id]?.neverSuspend = value
        if !value {
            Task { await sweep() }
        }
    }

    public func attachDisplay(sessionID: String, token: UUID) {
        displayTokens[sessionID] = token
        guard let session = sessions[sessionID] else { return }
        session.markVisible(true)
        session.wakeIfNeeded()
        Task { await enforceLiveLimit() }
    }

    public func detachDisplay(sessionID: String, token: UUID) {
        guard displayTokens[sessionID] == token else { return }
        displayTokens.removeValue(forKey: sessionID)
        guard let session = sessions[sessionID] else { return }
        session.markVisible(false)
        Task { await session.captureSnapshotIfPossible() }
    }

    /// 主窗口关闭时把所有已展示的网页标为后台，允许后续按规则进入休眠。
    public func detachAllDisplays() {
        displayTokens.removeAll()
        for session in sessions.values where session.isVisible {
            session.markVisible(false)
            Task { await session.captureSnapshotIfPossible() }
        }
    }

    // MARK: - 墓碑回收

    @discardableResult
    public func suspend(id: String, force: Bool = false) async -> Bool {
        guard let session = sessions[id] else { return false }
        return await session.suspendToTombstone(force: force)
    }

    @discardableResult
    public func suspendAllInactive() async -> Int {
        var count = 0
        for id in sessionIDs {
            guard let session = sessions[id], session.state == .active, !session.isVisible else { continue }
            if await session.suspendToTombstone(force: true) {
                count += 1
            }
        }
        return count
    }

    public func sweep(now: Date = Date()) async {
        guard tombstoneEnabled else { return }
        let minutes = idleMinutes
        if minutes > 0 {
            let threshold = TimeInterval(minutes * 60)
            for id in sessionIDs {
                guard let session = sessions[id],
                      session.state == .active,
                      !session.isVisible,
                      !session.neverSuspend,
                      now.timeIntervalSince(session.lastActiveAt) >= threshold else { continue }
                await session.suspendToTombstone(force: false)
            }
        }
        await enforceLiveLimit()
    }

    public func enforceLiveLimit() async {
        guard tombstoneEnabled else { return }
        let limit = maxLiveCount
        guard limit > 0 else { return }

        var activeCount = liveCount
        guard activeCount > limit else { return }

        let candidates = sessionIDs
            .compactMap { sessions[$0] }
            .filter { $0.state == .active && !$0.isVisible && !$0.neverSuspend }
            .sorted { $0.lastActiveAt < $1.lastActiveAt }

        for candidate in candidates {
            guard activeCount > limit else { break }
            if await candidate.suspendToTombstone(force: false) {
                activeCount -= 1
            }
        }
    }

    // MARK: - 清理与缓存

    public func remove(id: String) {
        displayTokens.removeValue(forKey: id)
        sessions.removeValue(forKey: id)?.teardown()
        sessionIDs.removeAll { $0 == id }
    }

    public func removeAll(where predicate: (String) -> Bool) {
        let targets = sessionIDs.filter(predicate)
        for id in targets {
            remove(id: id)
        }
    }

    public func reloadAllActive() {
        for session in sessions.values where session.state == .active {
            session.reload()
        }
    }

    public func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        for session in sessions.values {
            session.clearSavedState()
        }
        reloadAllActive()
    }

    public func stop() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        displayTokens.removeAll()
        for session in sessions.values {
            session.teardown()
        }
        sessions.removeAll()
        sessionIDs.removeAll()
    }
}
