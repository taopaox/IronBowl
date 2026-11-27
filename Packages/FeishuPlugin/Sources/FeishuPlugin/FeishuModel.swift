import Foundation
import IronBowlKit
import Observation

@Observable
public final class FeishuModel {
    public static let homePageID = "feishu.home"
    private static let blockedSchemes: Set<String> = ["feishu", "lark"]

    public let settings: SettingsStore
    public let webSessions: WebSessionManager
    @ObservationIgnored public let openPlugin: (String) -> Void
    @ObservationIgnored public let openSettings: (String?) -> Void

    public private(set) var activePageID: String?
    @ObservationIgnored private var ownedSessionIDs: Set<String> = [FeishuModel.homePageID]

    public convenience init(context: PluginContext) {
        self.init(
            settings: context.settings,
            webSessions: context.webSessions,
            openPlugin: context.openPlugin,
            openSettings: context.openSettings
        )
    }

    public init(
        settings: SettingsStore,
        webSessions: WebSessionManager? = nil,
        openPlugin: @escaping (String) -> Void = { _ in },
        openSettings: @escaping (String?) -> Void = { _ in }
    ) {
        self.settings = settings
        self.webSessions = webSessions ?? WebSessionManager(settings: settings)
        self.openPlugin = openPlugin
        self.openSettings = openSettings
        let savedLast = settings[FeishuKeys.lastPageID]
        let pinned = settings[FeishuKeys.pinnedPages]
        for p in pinned { ownedSessionIDs.insert(p.id) }
        if savedLast != Self.homePageID, pinned.contains(where: { $0.id == savedLast }) {
            self.activePageID = savedLast
        } else {
            self.activePageID = Self.homePageID
        }
    }

    public var homeURL: String {
        get {
            let raw = settings[FeishuKeys.homeURL].trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? FeishuURL.defaultHomeURL : raw
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? FeishuURL.defaultHomeURL : trimmed
            settings[FeishuKeys.homeURL] = value
            webSessions.existingSession(id: Self.homePageID)?.updateHomeURL(value, reload: false)
        }
    }

    public var homeNeverSuspend: Bool {
        get { settings[FeishuKeys.homeNeverSuspend] }
        set {
            settings[FeishuKeys.homeNeverSuspend] = newValue
            webSessions.setNeverSuspend(newValue, for: Self.homePageID)
        }
    }

    public func isNeverSuspend(pageID: String) -> Bool {
        if pageID == Self.homePageID {
            return homeNeverSuspend
        }
        return pinnedPages.first { $0.id == pageID }?.neverSuspend ?? false
    }

    public var pinnedPages: [FeishuPinnedPage] {
        get { settings[FeishuKeys.pinnedPages] }
        set { settings[FeishuKeys.pinnedPages] = newValue }
    }

    public var activePinnedPage: FeishuPinnedPage? {
        guard let activePageID, activePageID != Self.homePageID else { return nil }
        return pinnedPages.first { $0.id == activePageID }
    }

    public var activeSession: WebSession? {
        guard let activePageID else { return nil }
        return session(for: activePageID)
    }

    public func session(for pageID: String) -> WebSession {
        ownedSessionIDs.insert(pageID)
        let pin = pinnedPages.first { $0.id == pageID }
        let targetURL = pin?.url ?? homeURL
        return webSessions.session(
            id: pageID,
            initialURL: targetURL,
            blockedSchemes: Self.blockedSchemes,
            neverSuspend: isNeverSuspend(pageID: pageID),
            displayName: pin?.title ?? "飞书知识库"
        )
    }

    public func hasOpenSession(pageID: String) -> Bool {
        webSessions.hasSession(id: pageID)
    }

    public func ownsSession(id: String) -> Bool {
        id == Self.homePageID || ownedSessionIDs.contains(id) || pinnedPages.contains(where: { $0.id == id })
    }

    public func isSuspended(pageID: String) -> Bool {
        webSessions.isTombstoned(id: pageID)
    }

    public func selectHome() {
        webSessions.allowAutoWake(id: Self.homePageID)
        guard activePageID != Self.homePageID else { return }
        activePageID = Self.homePageID
        settings[FeishuKeys.lastPageID] = Self.homePageID
    }

    public func selectPage(_ id: String) {
        guard id == Self.homePageID || pinnedPages.contains(where: { $0.id == id }) else {
            selectHome()
            return
        }
        webSessions.allowAutoWake(id: id)
        guard activePageID != id else { return }
        activePageID = id
        settings[FeishuKeys.lastPageID] = id
    }

    public func closePage(id: String, navigateHomeIfActive: Bool = false) {
        let wasActive = (activePageID == id)
        let wasVisible = webSessions.existingSession(id: id)?.isVisible ?? false
        webSessions.remove(id: id)
        if id != Self.homePageID {
            ownedSessionIDs.remove(id)
        }
        if wasActive {
            activePageID = nil
            settings[FeishuKeys.lastPageID] = Self.homePageID
            if navigateHomeIfActive || wasVisible {
                openPlugin("home")
            }
        }
    }

    public func closeActivePage() {
        if let id = activePageID {
            closePage(id: id, navigateHomeIfActive: true)
        } else {
            openPlugin("home")
        }
    }

    @discardableResult
    public func pin(
        title: String,
        url: String,
        systemImage: String = "doc.text",
        neverSuspend: Bool = false
    ) -> FeishuPinnedPage? {
        guard let normalized = FeishuURL.normalize(url) else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty
            ? FeishuURL.cleanTitle(nil, fallbackURL: normalized.absoluteString)
            : trimmedTitle
        let page = FeishuPinnedPage(
            title: finalTitle,
            url: normalized.absoluteString,
            systemImage: systemImage,
            neverSuspend: neverSuspend
        )
        ownedSessionIDs.insert(page.id)
        var list = pinnedPages
        list.append(page)
        pinnedPages = list
        return page
    }

    public func pinnedPage(matchingURL url: String) -> FeishuPinnedPage? {
        pinnedPages.first { FeishuURL.isSamePage($0.url, url) }
    }

    public func updatePin(
        id: String,
        title: String,
        url: String? = nil,
        systemImage: String? = nil,
        neverSuspend: Bool? = nil
    ) {
        var list = pinnedPages
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            list[idx].title = trimmedTitle
        }
        var reloadSession = false
        if let url, let normalized = FeishuURL.normalize(url) {
            let nextURL = normalized.absoluteString
            if list[idx].url != nextURL {
                list[idx].url = nextURL
                reloadSession = true
            }
        }
        if let systemImage {
            list[idx].systemImage = systemImage
        }
        if let neverSuspend {
            list[idx].neverSuspend = neverSuspend
        }
        pinnedPages = list
        if !trimmedTitle.isEmpty {
            webSessions.setDisplayName(trimmedTitle, for: id)
        }
        if reloadSession {
            webSessions.existingSession(id: id)?.updateHomeURL(list[idx].url, reload: true)
        }
        if let neverSuspend {
            webSessions.setNeverSuspend(neverSuspend, for: id)
        }
    }

    public func renamePin(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePin(id: id, title: trimmed)
    }

    public func setNeverSuspend(_ value: Bool, id: String) {
        if id == Self.homePageID {
            homeNeverSuspend = value
        } else {
            updatePin(id: id, title: "", neverSuspend: value)
        }
    }

    public func suspendPage(id: String) async {
        await webSessions.suspend(id: id, force: true)
    }

    public func suspendActivePage() async {
        guard let id = activePageID else { return }
        await suspendPage(id: id)
    }

    public func movePin(id: String, delta: Int) {
        var list = pinnedPages
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard list.indices.contains(target) else { return }
        list.swapAt(index, target)
        pinnedPages = list
    }

    public func unpin(id: String) {
        pinnedPages = pinnedPages.filter { $0.id != id }
        webSessions.remove(id: id)
        ownedSessionIDs.remove(id)
        if activePageID == id {
            selectHome()
        }
    }

    public func reloadAllSessions() {
        for id in ownedSessionIDs {
            if let s = webSessions.existingSession(id: id), s.state == .active {
                s.reload()
            }
        }
    }

    public func clearWebsiteData() async {
        await webSessions.clearWebsiteData()
    }

    public func stop() {
        let ids = ownedSessionIDs.union(pinnedPages.map(\.id))
        webSessions.removeAll { ids.contains($0) }
        ownedSessionIDs = [Self.homePageID]
    }
}
