import AppKit
import Observation
import WebKit

/// 网页会话状态：活跃（持有 WKWebView 渲染进程）或已休眠（已墓碑化释放内存）。
public nonisolated enum WebSessionState: String, Equatable, Sendable {
    case active
    case tombstoned
}

/// 通用网页会话：支持 Chrome 式墓碑休眠（释放 WKWebView 渲染进程并保留历史栈与快照）。
@Observable
public final class WebSession {
    public let id: String
    public var homeURL: String
    public var blockedSchemes: Set<String>
    public var neverSuspend: Bool

    public private(set) var state: WebSessionState
    public private(set) var webView: WKWebView?
    public private(set) var snapshot: NSImage?
    public private(set) var isWakingUp = false
    public private(set) var isVisible = false
    public private(set) var deferAutoWake = false
    public var lastActiveAt = Date()
    public private(set) var tombstonedAt: Date?

    public var currentURL: String
    public var title = ""
    public var displayName: String?
    public var isLoading = false
    public var estimatedProgress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    public var errorMessage: String?
    public var downloadNotice: String?

    public var isTombstoned: Bool { state == .tombstoned }

    @ObservationIgnored private var savedInteractionState: Any?
    @ObservationIgnored private var coordinator: Coordinator?
    @ObservationIgnored private var wakeFallbackTask: Task<Void, Never>?
    @ObservationIgnored private let headlessForTesting: Bool

    public init(
        id: String,
        initialURL: String,
        blockedSchemes: Set<String> = [],
        neverSuspend: Bool = false,
        displayName: String? = nil,
        startActive: Bool = true,
        headlessForTesting: Bool = false
    ) {
        self.id = id
        self.homeURL = initialURL
        self.currentURL = initialURL
        self.blockedSchemes = blockedSchemes
        self.neverSuspend = neverSuspend
        self.displayName = displayName
        self.headlessForTesting = headlessForTesting
        self.deferAutoWake = !startActive
        self.state = startActive ? .active : .tombstoned
        if !startActive {
            self.tombstonedAt = Date()
        }
        if startActive, !headlessForTesting {
            createAndLoadWebView(urlString: initialURL, restoreInteractionState: nil)
        }
    }

    // MARK: - 导航控制

    public func load(urlString: String) {
        guard let url = WebURL.normalize(urlString) else {
            errorMessage = "无效网址：\(urlString)"
            return
        }
        errorMessage = nil
        currentURL = url.absoluteString
        wakeIfNeeded()
        webView?.load(URLRequest(url: url))
    }

    public func reload() {
        errorMessage = nil
        wakeIfNeeded()
        guard let webView else { return }
        if webView.url == nil {
            load(urlString: currentURL)
        } else {
            webView.reload()
        }
    }

    public func stopLoading() {
        webView?.stopLoading()
    }

    public func goBack() {
        if let webView, webView.canGoBack { webView.goBack() }
    }

    public func goForward() {
        if let webView, webView.canGoForward { webView.goForward() }
    }

    public func goHome() {
        load(urlString: homeURL)
    }

    public func updateHomeURL(_ url: String, reload: Bool) {
        homeURL = url
        if reload {
            currentURL = url
            savedInteractionState = nil
            snapshot = nil
            if state == .active {
                load(urlString: url)
            }
        }
    }

    public func clearSavedState() {
        savedInteractionState = nil
        snapshot = nil
    }

    // MARK: - 墓碑与唤醒

    public func markVisible(_ visible: Bool) {
        isVisible = visible
        lastActiveAt = Date()
    }

    public func captureSnapshotIfPossible() async {
        guard let wv = webView,
              wv.window != nil,
              wv.bounds.width > 10,
              wv.bounds.height > 10 else { return }
        if let image = try? await wv.takeSnapshot(configuration: nil) {
            snapshot = image
        }
    }

    /// 检查当前是否适合自动休眠（正在显示、免休眠、音视频播放或麦克风/摄像头使用中均跳过）。
    public func canAutoSuspend() async -> Bool {
        guard state == .active, !isVisible, !neverSuspend else { return false }
        guard let wv = webView else { return true }
        if wv.cameraCaptureState == .active || wv.microphoneCaptureState == .active {
            return false
        }
        let playback = await wv.requestMediaPlaybackState()
        return playback != .playing
    }

    @discardableResult
    public func suspendToTombstone(force: Bool = false) async -> Bool {
        guard state == .active else { return false }
        if !force {
            guard await canAutoSuspend() else { return false }
        }
        if let wv = webView {
            if snapshot == nil {
                await captureSnapshotIfPossible()
            }
            syncFromWebView()
            savedInteractionState = wv.interactionState
            destroyWebView(wv)
        }
        wakeFallbackTask?.cancel()
        wakeFallbackTask = nil
        isLoading = false
        estimatedProgress = 0
        isWakingUp = false
        deferAutoWake = force && isVisible
        state = .tombstoned
        tombstonedAt = Date()
        return true
    }

    public func wakeIfNeeded() {
        lastActiveAt = Date()
        deferAutoWake = false
        guard state == .tombstoned else { return }
        state = .active
        tombstonedAt = nil
        guard !headlessForTesting else { return }
        let restore = savedInteractionState
        createAndLoadWebView(urlString: currentURL, restoreInteractionState: restore)
    }

    public func allowAutoWake() {
        deferAutoWake = false
        if isVisible {
            wakeIfNeeded()
        }
    }

    public func teardown() {
        wakeFallbackTask?.cancel()
        wakeFallbackTask = nil
        if let wv = webView {
            destroyWebView(wv)
        }
    }

    // MARK: - 内部实现

    private func createAndLoadWebView(urlString: String, restoreInteractionState: Any?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true

        let coordinator = Coordinator()
        coordinator.session = self
        wv.navigationDelegate = coordinator
        wv.uiDelegate = coordinator
        coordinator.observe(wv)

        self.coordinator = coordinator
        self.webView = wv

        if let restoreInteractionState {
            isWakingUp = (snapshot != nil)
            wv.interactionState = restoreInteractionState
            if wv.url == nil, let url = WebURL.normalize(urlString) {
                wv.load(URLRequest(url: url))
            }
            scheduleWakeFallback()
        } else if let url = WebURL.normalize(urlString) {
            isWakingUp = false
            wv.load(URLRequest(url: url))
        }
    }

    private func destroyWebView(_ wv: WKWebView) {
        coordinator?.invalidate()
        coordinator = nil
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.uiDelegate = nil
        wv.removeFromSuperview()
        webView = nil
    }

    private func finishWakePlaceholder() {
        wakeFallbackTask?.cancel()
        wakeFallbackTask = nil
        isWakingUp = false
        snapshot = nil
    }

    private func scheduleWakeFallback() {
        wakeFallbackTask?.cancel()
        wakeFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.finishWakePlaceholder()
        }
    }

    fileprivate func syncFromWebView() {
        guard let wv = webView else { return }
        if let url = wv.url?.absoluteString, !url.isEmpty {
            currentURL = url
        }
        if let t = wv.title, !t.isEmpty {
            title = t
        }
        isLoading = wv.isLoading
        estimatedProgress = wv.estimatedProgress
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
    }

    fileprivate func handleProcessTerminated() {
        if isVisible, let wv = webView {
            wv.reload()
        } else {
            if let wv = webView {
                destroyWebView(wv)
            }
            isLoading = false
            estimatedProgress = 0
            isWakingUp = false
            state = .tombstoned
            tombstonedAt = Date()
        }
    }

    // MARK: - Coordinator

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        weak var session: WebSession?
        private var observations: [NSKeyValueObservation] = []

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.session?.syncFromWebView() }
                },
            ]
        }

        func invalidate() {
            for obs in observations { obs.invalidate() }
            observations.removeAll()
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo
        ) async {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "好")
            if let window = webView.window {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    completionHandler(response == .alertFirstButtonReturn)
                }
            } else {
                completionHandler(alert.runModal() == .alertFirstButtonReturn)
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
                }
            } else {
                completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if let blocked = session?.blockedSchemes, blocked.contains(scheme) {
                decisionHandler(.cancel)
                return
            }
            switch scheme {
            case "http", "https", "about", "blob", "data":
                decisionHandler(.allow)
            case "mailto", "tel":
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            default:
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            session?.errorMessage = nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            session?.errorMessage = nil
            if session?.isWakingUp == true {
                session?.scheduleWakeFallback()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            session?.finishWakePlaceholder()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            session?.finishWakePlaceholder()
            handleError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            session?.finishWakePlaceholder()
            handleError(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            session?.handleProcessTerminated()
        }

        private func handleError(_ error: any Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
            session?.errorMessage = error.localizedDescription
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor (URL?) -> Void
        ) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            if let window = session?.webView?.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.url : nil)
                }
            } else {
                completionHandler(panel.runModal() == .OK ? panel.url : nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            let name = download.progress.fileURL?.lastPathComponent ?? "文件"
            session?.downloadNotice = "已下载：\(name)"
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            session?.errorMessage = "下载失败：\(error.localizedDescription)"
        }
    }
}
