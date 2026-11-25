import AppKit
import IronBowlKit
import SwiftUI
import WebKit

// MARK: - Tita 设置页

struct TitaAccountSettings: View {
    let model: WeeklyReportModel
    @State private var rawCredentialInput = ""
    @State private var showWebLogin = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var isSuccess = false

    private var connectionSummary: String {
        guard model.isTitaConfigured else { return "尚未配置 Tita 登录凭证" }
        var parts: [String] = []
        if !model.titaUserName.isEmpty { parts.append(model.titaUserName) }
        if !model.titaTenantID.isEmpty { parts.append("租户 \(model.titaTenantID)") }
        if !model.titaUserID.isEmpty { parts.append("用户 \(model.titaUserID)") }
        return parts.isEmpty ? "已保存 Cookie（点击「测试连接」自动识别身份）" : parts.joined(separator: " · ")
    }

    var body: some View {
        let s = model.settings

        DSSection("Tita 登录态", footer: "支持通过内置网页登录自动提取 Cookie，或直接粘贴浏览器请求头 / cURL；Cookie 保存在本机数据库（~/Library/Application Support/IronBowl/ironbowl.sqlite）。") {
            DSRow("当前状态", description: connectionSummary) {
                HStack(spacing: 8) {
                    if model.isTitaConfigured {
                        Button("清空登录态") {
                            Task { await clearAllTitaCookies() }
                        }
                        .buttonStyle(.dsSecondary)
                    }
                    Button("内置网页登录并提取") {
                        showWebLogin = true
                    }
                    .buttonStyle(.dsPrimary)
                }
            }
        }

        DSSection("导入 Cookie 或 Copy as cURL", footer: "在 Chrome 打开 Tita 页面 → 开发者工具 → Network → 任意接口右键 Copy as cURL，或复制 Cookie 请求头粘贴到此处。") {
            DSBlockRow {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        if rawCredentialInput.isEmpty {
                            Text("粘贴完整 curl '...' 命令、Cookie: ... 请求头，或纯 Cookie 字符串…")
                                .font(DS.mono(12.5))
                                .foregroundStyle(DS.textTertiary)
                                .padding(.top, 4)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $rawCredentialInput)
                            .font(DS.mono(12.5))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 88, maxHeight: 140)
                    }
                    .padding(8)
                    .background(DS.well.opacity(0.6), in: .rect(cornerRadius: DS.controlRadius))

                    HStack {
                        if !rawCredentialInput.isEmpty {
                            Button("清空输入") {
                                rawCredentialInput = ""
                            }
                            .buttonStyle(.dsGhost)
                        }
                        Spacer()
                        Button {
                            Task { await parseAndVerify() }
                        } label: {
                            if testing {
                                ProgressView().controlSize(.small).tint(DS.onPrimary)
                            } else {
                                Text("解析并测试连接")
                            }
                        }
                        .buttonStyle(.dsPrimary)
                        .disabled(testing || rawCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }

        DSSection("服务器与模板参数") {
            DSRow("Tita 地址") {
                TextField("", text: s.binding(ReportKeys.titaBaseURL))
                    .textFieldStyle(.ds)
                    .frame(width: 280)
            }
            DSRow("租户 ID", description: "测试连接时会自动从 Tita 首页识别填充。") {
                TextField("", text: s.binding(ReportKeys.titaTenantID))
                    .textFieldStyle(.ds)
                    .frame(width: 180)
            }
            DSRow("用户 ID", description: "测试连接时会自动识别填充。") {
                TextField("", text: s.binding(ReportKeys.titaUserID))
                    .textFieldStyle(.ds)
                    .frame(width: 180)
            }
            DSRow("周报模板 ID", description: "默认 1006，测试连接时会自动匹配当前企业模板。") {
                TextField("", value: s.binding(ReportKeys.titaWeeklyTemplateID), format: .number.grouping(.never))
                    .textFieldStyle(.ds)
                    .frame(width: 120)
            }
            DSRow("月报模板 ID", description: "默认 1007，测试连接时会自动匹配当前企业模板。") {
                TextField("", value: s.binding(ReportKeys.titaMonthlyTemplateID), format: .number.grouping(.never))
                    .textFieldStyle(.ds)
                    .frame(width: 120)
            }
            DSRow("默认心情") {
                DSPicker(
                    selection: Binding(
                        get: { TitaMood(rawValue: s[ReportKeys.titaDefaultMood]) ?? .unset },
                        set: { s[ReportKeys.titaDefaultMood] = $0.rawValue }
                    ),
                    options: TitaMood.allCases.map { DSPickerOption($0, title: $0.displayName) },
                    width: 140
                )
            }
        }

        DSSection("连接诊断", footer: "每次调用 Tita 的请求状态与脱敏响应会写入 tita.log（不包含 Cookie 明文）。") {
            DSRow("测试连接", description: testResult ?? "验证当前 Cookie 是否有效并自动同步周报/月报模板。") {
                HStack(spacing: 8) {
                    Button("打开接口日志") {
                        NSWorkspace.shared.open(TitaLog.url)
                    }
                    .buttonStyle(.dsGhost)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small).tint(DS.onPrimary)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(testing || !model.isTitaConfigured)
                }
            }
            if let testResult {
                DSBlockRow {
                    DSBanner(isSuccess ? .success : .danger, testResult)
                }
            }
        }
        .sheet(isPresented: $showWebLogin) {
            TitaWebLoginSheet(model: model) { info in
                isSuccess = true
                testResult = "已通过内置网页提取 Cookie，当前账号：\(info.userName.isEmpty ? info.userID : info.userName)（租户 \(info.tenantID)）"
            }
        }
    }

    private func parseAndVerify() async {
        let parsed = model.applyTitaCredentialInput(rawCredentialInput)
        if parsed.cookie.isEmpty {
            isSuccess = false
            testResult = "未从输入内容中识别到有效的 Cookie。"
            return
        }
        await testConnection()
        if isSuccess {
            rawCredentialInput = ""
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let info = try await model.verifyTitaAccount()
            await model.refreshTitaStatus()
            isSuccess = true
            let nameLabel = info.userName.isEmpty ? info.userID : info.userName
            testResult = "连接成功：\(nameLabel)（租户 \(info.tenantID) · 用户 \(info.userID)），模板已自动同步。"
        } catch {
            isSuccess = false
            testResult = error.localizedDescription
        }
    }

    private func clearAllTitaCookies() async {
        model.clearTitaSession()
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where cookie.domain.lowercased().contains("tita.net") {
            await store.deleteCookie(cookie)
        }
        isSuccess = true
        testResult = "已清空本地 Tita 登录态与 Cookie。"
    }
}

// MARK: - 内置网页登录提取 Cookie

struct TitaWebLoginSheet: View {
    let model: WeeklyReportModel
    var onSuccess: ((TitaAccountInfo) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var currentURLText = ""
    @State private var isLoadingPage = false
    @State private var isExtracting = false
    @State private var hasAutoExtracted = false
    @State private var reloadToken = UUID()
    @State private var statusBanner: (DSBanner.Kind, String)?

    private var loginURL: URL {
        var base = model.titaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base.isEmpty ? "https://www.tita.net" : base)/login/#/login")
            ?? URL(string: "https://www.tita.net/login/#/login")!
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("登录 Tita 并提取 Cookie")
                        .font(DS.font(16, .semibold))
                    Text(currentURLText.isEmpty ? loginURL.absoluteString : currentURLText)
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isLoadingPage || isExtracting {
                    ProgressView().controlSize(.small)
                }

                Button("刷新") {
                    hasAutoExtracted = false
                    reloadToken = UUID()
                }
                .buttonStyle(.dsSecondary)

                Button("我已登录，立即提取") {
                    Task { await extractCookiesAndVerify(manual: true) }
                }
                .buttonStyle(.dsPrimary)
                .disabled(isExtracting)

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(DS.sidebar)

            Divider().overlay(DS.border)

            if let statusBanner {
                DSBanner(statusBanner.0, statusBanner.1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(DS.canvas)
            }

            TitaLoginWebView(
                initialURL: loginURL,
                reloadToken: reloadToken,
                onURLChange: { urlText in
                    currentURLText = urlText
                    if !hasAutoExtracted, isAuthenticatedURL(urlText) {
                        hasAutoExtracted = true
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            await extractCookiesAndVerify(manual: false)
                        }
                    }
                },
                onLoadingChange: { loading in
                    isLoadingPage = loading
                }
            )
        }
        .frame(width: DS.s(920), height: DS.s(640))
    }

    private func isAuthenticatedURL(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        guard lower.contains("tita.net") else { return false }
        guard !lower.contains("/login") else { return false }
        return lower.contains("/u/") || lower.contains("#/dynamic") || lower.contains("#/okr") || lower.contains("#/summary")
    }

    private func extractCookiesAndVerify(manual: Bool) async {
        guard !isExtracting else { return }
        isExtracting = true
        defer { isExtracting = false }

        let allCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let titaCookies = allCookies.filter { $0.domain.lowercased().contains("tita.net") }
        let cookieHeader = titaCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        guard !cookieHeader.isEmpty else {
            if manual {
                statusBanner = (.warning, "暂未检测到 tita.net 的登录 Cookie，请先在下方网页完成登录。")
            }
            hasAutoExtracted = false
            return
        }

        model.settings[ReportKeys.titaCookie] = cookieHeader
        do {
            let info = try await model.verifyTitaAccount()
            await model.refreshTitaStatus()
            onSuccess?(info)
            dismiss()
        } catch {
            hasAutoExtracted = false
            if manual {
                statusBanner = (.danger, "Cookie 提取后校验失败：\(error.localizedDescription)")
            }
        }
    }
}

private struct TitaLoginWebView: NSViewRepresentable {
    let initialURL: URL
    let reloadToken: UUID
    let onURLChange: (String) -> Void
    let onLoadingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange, onLoadingChange: onLoadingChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15"

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.observe(webView)
        context.coordinator.lastReloadToken = reloadToken
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: initialURL))
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onURLChange: (String) -> Void
        let onLoadingChange: (Bool) -> Void
        var lastReloadToken = UUID()
        private var observations: [NSKeyValueObservation] = []
        private let blockedSchemes: Set<String> = ["dingtalk", "feishu", "lark", "wxwork"]

        init(onURLChange: @escaping (String) -> Void, onLoadingChange: @escaping (Bool) -> Void) {
            self.onURLChange = onURLChange
            self.onLoadingChange = onLoadingChange
        }

        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor [weak self, weak webView] in
                        self?.onURLChange(webView?.url?.absoluteString ?? "")
                    }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self, weak webView] _, _ in
                    Task { @MainActor [weak self, weak webView] in
                        self?.onLoadingChange(webView?.isLoading ?? false)
                    }
                },
            ]
        }

        func invalidate() {
            for obs in observations { obs.invalidate() }
            observations.removeAll()
        }

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
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow)
                return
            }
            if blockedSchemes.contains(scheme) {
                decisionHandler(.cancel)
                return
            }
            if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme == "data" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

// MARK: - 推送到 Tita 预览与提交弹窗

struct TitaSubmitSheet: View {
    @Bindable var model: WeeklyReportModel

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var loadError: String?
    @State private var isAuthError = false
    @State private var actionError: String?

    @State private var templateID: Int = 1006
    @State private var remoteState: TitaSubmitState = .none
    @State private var delayDate: String?
    @State private var mood: TitaMood = .unset
    @State private var modules: [TitaEditableModule] = []

    @State private var confirmSubmit = false
    @State private var showWebLogin = false

    private var hasAnyRemoteContent: Bool {
        modules.contains { !$0.existingRemoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var stateTagColor: Color {
        switch remoteState {
        case .onTime: DS.success
        case .delay: DS.warning
        case .unSubmit: DS.brand
        case .none: DS.textSecondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            Divider().overlay(DS.border)

            if !model.isTitaConfigured {
                onboardingBody
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在拉取 Tita \(model.periodKind.displayName)模板与当前状态…")
                        .font(DS.body)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.canvas)
            } else if let loadError {
                errorBody(loadError)
            } else {
                editorBody
            }

            Divider().overlay(DS.border)

            sheetFooter
        }
        .frame(width: DS.s(760), height: DS.s(640))
        .background(DS.canvas)
        .task {
            if model.isTitaConfigured {
                await loadEditor()
            }
        }
        .sheet(isPresented: $showWebLogin) {
            TitaWebLoginSheet(model: model) { _ in
                Task { await loadEditor() }
            }
        }
        .alert(
            remoteState.isSubmitted ? "确认更新已提交的 Tita \(model.periodKind.displayName)？" : "确认提交\(model.periodKind.displayName)到 Tita？",
            isPresented: $confirmSubmit
        ) {
            Button(remoteState.isSubmitted ? "确认更新" : "确认提交") {
                Task { await performSubmit() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把当前 \(modules.count) 个模块内容同步并正式\(remoteState.isSubmitted ? "更新" : "提交")到 Tita（周期 \(model.activeTitaSummaryDate)）。")
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("推送到 Tita · \(model.activePeriodTitle)")
                        .font(DS.font(16, .semibold))
                    if model.isTitaConfigured && !isLoading && loadError == nil {
                        Tag(remoteState.displayName, color: stateTagColor)
                    }
                }
                HStack(spacing: 8) {
                    Text("Tita 周期：\(model.activeTitaSummaryDate)")
                    Text("·")
                    Text("模板 #\(templateID)")
                    if let delayDate, !delayDate.isEmpty, !remoteState.isSubmitted {
                        Text("·")
                        Text("截止 \(delayDate)")
                    }
                }
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
            }

            Spacer(minLength: 8)

            if !model.titaUserID.isEmpty {
                Button {
                    model.openActiveTitaInBrowser()
                } label: {
                    Label("在浏览器打开", systemImage: "safari")
                }
                .buttonStyle(.dsGhost)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(DS.sidebar)
    }

    private var onboardingBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "paperplane.circle")
                .font(DS.font(34))
                .foregroundStyle(DS.textSecondary)

            Text("尚未连接 Tita 账号")
                .font(DS.font(17, .semibold))

            Text("你可以直接通过内置网页登录 Tita 自动提取 Cookie，或在设置中粘贴 Chrome DevTools 的请求头 / Copy as cURL。")
                .font(DS.body)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 10) {
                Button("内置网页登录并提取") {
                    showWebLogin = true
                }
                .buttonStyle(.dsPrimary)

                Button("前往配置 Cookie / cURL") {
                    dismiss()
                    model.context.openSettings(ReportPlugin.settingsTitaID)
                }
                .buttonStyle(.dsSecondary)
            }
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBody(_ text: String) -> some View {
        VStack(spacing: 14) {
            DSBanner(.danger, text)
                .frame(maxWidth: 520)

            HStack(spacing: 10) {
                if isAuthError {
                    Button("重新登录提取 Cookie") {
                        showWebLogin = true
                    }
                    .buttonStyle(.dsPrimary)
                }
                Button("重试") {
                    Task { await loadEditor() }
                }
                .buttonStyle(.dsSecondary)

                Button("前往 Tita 设置") {
                    dismiss()
                    model.context.openSettings(ReportPlugin.settingsTitaID)
                }
                .buttonStyle(.dsGhost)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let actionError {
                    DSBanner(.danger, actionError)
                }

                HStack(spacing: 10) {
                    Text("心情")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    DSPicker(
                        selection: $mood,
                        options: TitaMood.allCases.map { DSPickerOption($0, title: $0.displayName) },
                        width: 120
                    )

                    Spacer(minLength: 8)

                    Button("用本地报告填充") {
                        fillFromLocalReport()
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(!model.hasReportContent)

                    if hasAnyRemoteContent {
                        Button("加载 Tita 已有内容") {
                            fillFromRemoteContent()
                        }
                        .buttonStyle(.dsGhost)
                    }
                }

                ForEach($modules) { $module in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(module.moduleName)
                                .font(DS.font(13.5, .semibold))
                                .foregroundStyle(DS.text)
                            Spacer()
                            Text("\(module.text.count) / 10000")
                                .font(DS.font(11.5).monospacedDigit())
                                .foregroundStyle(module.text.count > 10_000 ? DS.danger : DS.textTertiary)
                        }

                        TextEditor(text: $module.text)
                            .font(DS.body)
                            .lineSpacing(4)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 108, maxHeight: 180)
                            .padding(8)
                            .background(DS.well.opacity(0.55), in: .rect(cornerRadius: DS.controlRadius))
                    }
                    .padding(14)
                    .background(DS.card, in: .rect(cornerRadius: DS.radius))
                    .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
                }
            }
            .padding(20)
        }
    }

    private var sheetFooter: some View {
        HStack(spacing: 10) {
            Button("取消") {
                dismiss()
            }
            .buttonStyle(.dsGhost)
            .disabled(isSubmitting)

            Spacer()

            if model.isTitaConfigured && loadError == nil && !isLoading {
                Button {
                    Task { await performSaveDraft() }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("存为 Tita 草稿")
                    }
                }
                .buttonStyle(.dsSecondary)
                .disabled(isSubmitting || modules.isEmpty)

                Button {
                    confirmSubmit = true
                } label: {
                    Text(remoteState.isSubmitted ? "更新到 Tita" : "提交到 Tita")
                }
                .buttonStyle(.dsPrimary)
                .disabled(isSubmitting || modules.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DS.sidebar)
    }

    private func loadEditor() async {
        isLoading = true
        loadError = nil
        isAuthError = false
        actionError = nil
        templateID = model.activeTitaTemplateID
        defer { isLoading = false }

        do {
            let prepared = try await model.prepareTitaEditor()
            templateID = prepared.templateID
            remoteState = prepared.remoteState
            delayDate = prepared.delayDate
            mood = prepared.mood
            modules = prepared.modules
        } catch {
            if let titaErr = error as? TitaError {
                switch titaErr {
                case .sessionExpired, .notConfigured, .missingIdentity:
                    isAuthError = true
                default:
                    isAuthError = false
                }
            }
            loadError = error.localizedDescription
        }
    }

    private func fillFromLocalReport() {
        let mapped = TitaContentMapper.map(markdown: model.reportContent, toModules: modules.map(\.moduleName))
        for i in modules.indices where i < mapped.count {
            modules[i].text = mapped[i]
        }
    }

    private func fillFromRemoteContent() {
        for i in modules.indices {
            modules[i].text = modules[i].existingRemoteText
        }
    }

    private func performSaveDraft() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            _ = try await model.saveDraftToTita(templateID: templateID, modules: modules, mood: mood)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func performSubmit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            _ = try await model.submitToTita(templateID: templateID, modules: modules, mood: mood)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
