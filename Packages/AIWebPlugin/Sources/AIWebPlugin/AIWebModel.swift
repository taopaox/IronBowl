import Foundation
import IronBowlKit
import Observation

public struct AIEditorTarget: Identifiable, Equatable {
    public let id: String
    public let app: AIWebApp?

    public static var create: AIEditorTarget {
        AIEditorTarget(id: "new-\(UUID().uuidString)", app: nil)
    }

    public static func edit(_ app: AIWebApp) -> AIEditorTarget {
        AIEditorTarget(id: app.id, app: app)
    }
}

@Observable
public final class AIWebModel {
    public let settings: SettingsStore
    public let webSessions: WebSessionManager
    public let logoStore: AILogoStore
    @ObservationIgnored public let openPlugin: (String) -> Void
    @ObservationIgnored public let openSettings: (String?) -> Void

    public private(set) var activeAppID: String?
    public var editorTarget: AIEditorTarget?
    @ObservationIgnored private var ownedSessionIDs: Set<String> = []

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
        logoStore: AILogoStore? = nil,
        openPlugin: @escaping (String) -> Void = { _ in },
        openSettings: @escaping (String?) -> Void = { _ in }
    ) {
        self.settings = settings
        self.webSessions = webSessions ?? WebSessionManager(settings: settings)
        self.logoStore = logoStore ?? AILogoStore()
        self.openPlugin = openPlugin
        self.openSettings = openSettings

        if settings[AIWebKeys.apps] == nil {
            settings[AIWebKeys.apps] = AIWebPresets.all
        }

        let currentApps = settings[AIWebKeys.apps] ?? []
        let savedActive = settings[AIWebKeys.activeAppID]
        if let savedActive, currentApps.contains(where: { $0.id == savedActive }) {
            self.activeAppID = savedActive
        } else {
            self.activeAppID = nil
            if savedActive != nil {
                settings[AIWebKeys.activeAppID] = nil
            }
        }
    }

    // MARK: - 列表与状态

    public var apps: [AIWebApp] {
        get { settings[AIWebKeys.apps] ?? [] }
        set { settings[AIWebKeys.apps] = newValue }
    }

    public var pinnedApps: [AIWebApp] {
        apps.filter(\.isPinned)
    }

    public var activeApp: AIWebApp? {
        guard let activeAppID else { return nil }
        return apps.first { $0.id == activeAppID }
    }

    public var activeSession: WebSession? {
        guard let activeApp else { return nil }
        return session(for: activeApp)
    }

    public func app(withID id: String) -> AIWebApp? {
        apps.first { $0.id == id }
    }

    public func sessionID(for appID: String) -> String {
        "aiweb.\(appID)"
    }

    public func session(for app: AIWebApp) -> WebSession {
        let sid = sessionID(for: app.id)
        ownedSessionIDs.insert(sid)
        return webSessions.session(
            id: sid,
            initialURL: app.url,
            neverSuspend: app.neverSuspend,
            displayName: app.name
        )
    }

    public func existingSession(for appID: String) -> WebSession? {
        webSessions.existingSession(id: sessionID(for: appID))
    }

    public func hasOpenSession(appID: String) -> Bool {
        webSessions.hasSession(id: sessionID(for: appID))
    }

    public func isSuspended(appID: String) -> Bool {
        webSessions.isTombstoned(id: sessionID(for: appID))
    }

    // MARK: - 导航

    public func selectDirectory() {
        activeAppID = nil
        settings[AIWebKeys.activeAppID] = nil
    }

    public func selectApp(_ id: String) {
        guard apps.contains(where: { $0.id == id }) else {
            selectDirectory()
            return
        }
        activeAppID = id
        settings[AIWebKeys.activeAppID] = id
    }

    public func closeApp(id: String) {
        let sid = sessionID(for: id)
        webSessions.remove(id: sid)
        ownedSessionIDs.remove(sid)
        if activeAppID == id {
            selectDirectory()
        }
    }

    public func beginCreating() {
        editorTarget = .create
    }

    public func beginEditing(appID: String) {
        guard let target = app(withID: appID) else { return }
        editorTarget = .edit(target)
    }

    // MARK: - 增删改查

    @discardableResult
    public func addApp(
        name: String,
        url: String,
        description: String = "",
        category: AICategory = .custom,
        logo: AILogoSource = .symbol("sparkles"),
        isPinned: Bool = true,
        neverSuspend: Bool = false
    ) -> AIWebApp? {
        guard let normalized = WebURL.normalize(url) else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty
            ? WebURL.cleanTitle(nil, fallbackURL: normalized.absoluteString)
            : trimmedName
        let item = AIWebApp(
            name: finalName,
            url: normalized.absoluteString,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            logo: logo,
            isPinned: isPinned,
            neverSuspend: neverSuspend,
            isBuiltIn: false,
            presetID: nil
        )
        var list = apps
        list.append(item)
        apps = list
        return item
    }

    public func updateApp(
        id: String,
        name: String? = nil,
        url: String? = nil,
        description: String? = nil,
        category: AICategory? = nil,
        logo: AILogoSource? = nil,
        isPinned: Bool? = nil,
        neverSuspend: Bool? = nil
    ) {
        var list = apps
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        let previousLogo = list[idx].logo

        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                list[idx].name = trimmed
            }
        }
        var reloadSession = false
        if let url, let normalized = WebURL.normalize(url) {
            let nextURL = normalized.absoluteString
            if list[idx].url != nextURL {
                list[idx].url = nextURL
                reloadSession = true
            }
        }
        if let description {
            list[idx].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let category {
            list[idx].category = category
        }
        if let logo {
            list[idx].logo = logo
        }
        if let isPinned {
            list[idx].isPinned = isPinned
        }
        if let neverSuspend {
            list[idx].neverSuspend = neverSuspend
        }

        apps = list

        if case let .localFile(oldFilename) = previousLogo, list[idx].logo != previousLogo {
            logoStore.deleteLocalFileIfUnused(oldFilename, apps: list)
        }

        let sid = sessionID(for: id)
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webSessions.setDisplayName(list[idx].name, for: sid)
        }
        if reloadSession {
            webSessions.existingSession(id: sid)?.updateHomeURL(list[idx].url, reload: true)
        }
        if let neverSuspend {
            webSessions.setNeverSuspend(neverSuspend, for: sid)
        }
    }

    public func renameApp(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateApp(id: id, name: trimmed)
    }

    public func deleteApp(id: String) {
        let removed = app(withID: id)
        let remaining = apps.filter { $0.id != id }
        apps = remaining
        if case let .localFile(filename) = removed?.logo {
            logoStore.deleteLocalFileIfUnused(filename, apps: remaining)
        }
        let sid = sessionID(for: id)
        webSessions.remove(id: sid)
        ownedSessionIDs.remove(sid)
        if activeAppID == id {
            selectDirectory()
        }
    }

    public func setPinned(_ pinned: Bool, id: String) {
        updateApp(id: id, isPinned: pinned)
    }

    public func togglePin(id: String) {
        guard let target = app(withID: id) else { return }
        setPinned(!target.isPinned, id: id)
    }

    public func setNeverSuspend(_ value: Bool, id: String) {
        updateApp(id: id, neverSuspend: value)
    }

    /// 只在已固定项之间交换顺序，保证每次点击在左侧栏立即可见。
    public func movePinnedApp(id: String, delta: Int) {
        guard delta != 0 else { return }
        var list = apps
        let pinnedIndices = list.indices.filter { list[$0].isPinned }
        guard let pos = pinnedIndices.firstIndex(where: { list[$0].id == id }) else { return }
        let targetPos = pos + delta
        guard pinnedIndices.indices.contains(targetPos) else { return }
        list.swapAt(pinnedIndices[pos], pinnedIndices[targetPos])
        apps = list
    }

    public func suspendApp(id: String) async {
        await webSessions.suspend(id: sessionID(for: id), force: true)
    }

    @discardableResult
    public func restoreMissingPresets() -> Int {
        var list = apps
        let existingPresetIDs = Set(list.compactMap(\.presetID))
        let existingIDs = Set(list.map(\.id))
        let missing = AIWebPresets.all.filter { preset in
            let pKey = preset.presetID ?? preset.id
            return !existingPresetIDs.contains(pKey) && !existingIDs.contains(preset.id)
        }
        guard !missing.isEmpty else { return 0 }
        list.append(contentsOf: missing)
        apps = list
        return missing.count
    }

    public func resetToPresets() {
        let currentApps = apps
        let sids = ownedSessionIDs.union(currentApps.map { sessionID(for: $0.id) })
        webSessions.removeAll { sids.contains($0) }
        ownedSessionIDs.removeAll()
        apps = AIWebPresets.all
        for item in currentApps {
            if case let .localFile(filename) = item.logo {
                logoStore.deleteLocalFileIfUnused(filename, apps: AIWebPresets.all)
            }
        }
        selectDirectory()
    }

    public func stop() {
        let sids = ownedSessionIDs.union(apps.map { sessionID(for: $0.id) })
        webSessions.removeAll { sids.contains($0) }
        ownedSessionIDs.removeAll()
    }
}
