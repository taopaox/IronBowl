import AppKit
import IronBowlKit
import SwiftUI

/// 通过本机 `lark-cli` 读取飞书子文档素材或覆盖写入目标飞书文档的弹窗。
struct FeishuDocExportSheet: View {
    @Bindable var model: WeeklyReportModel

    @Environment(\.dismiss) private var dismiss
    @State private var cliPath: String?
    @State private var authStatus: FeishuAuthStatus?
    @State private var deviceLogin: FeishuDeviceLoginInfo?
    @State private var docURLInput: String = ""

    @State private var isCheckingAuth = false
    @State private var isAuthorizing = false
    @State private var isImportingChildren = false
    @State private var isWritingDoc = false
    @State private var confirmOverwrite = false

    @State private var statusMessage: (DSBanner.Kind, String)?
    @State private var writeResult: FeishuDocWriteResult?

    init(model: WeeklyReportModel) {
        self._model = Bindable(model)
        self._docURLInput = State(initialValue: model.feishuMonthlyDocURL)
    }

    private var trimmedDocURL: String {
        docURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isAuthorized: Bool {
        authStatus?.isAvailable == true
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    authCard
                    targetDocumentCard
                    if let statusMessage {
                        DSBanner(statusMessage.0, statusMessage.1)
                    }
                    if let writeResult {
                        writeResultCard(writeResult)
                    }
                }
                .padding(20)
            }

            Divider().overlay(DS.border)
            sheetFooter
        }
        .frame(width: DS.s(720), height: DS.s(560))
        .background(DS.canvas)
        .task {
            await checkCLIAndAuth()
        }
        .alert("确认覆盖写入飞书文档？", isPresented: $confirmOverwrite) {
            Button("确认覆盖写入", role: .destructive) {
                Task { await performOverwrite() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将使用当前「\(model.activePeriodTitle)」\(model.periodKind.displayName)全文覆盖写入目标飞书文档，并在写入后自动回读验证。")
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("写入飞书文档 · \(model.activePeriodTitle)")
                    .font(DS.font(16, .semibold))
                Text("调用本机 lark-cli 读取子周报素材，或将当前\(model.periodKind.displayName)覆盖写入目标飞书文档并回读确认。")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Spacer()
            if !trimmedDocURL.isEmpty, let url = URL(string: trimmedDocURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("浏览器打开", systemImage: "safari")
                }
                .buttonStyle(.dsGhost)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(DS.sidebar)
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("飞书 CLI 授权状态")
                    .font(DS.font(13.5, .semibold))
                if let cliPath {
                    Tag(URL(fileURLWithPath: cliPath).lastPathComponent, color: DS.textSecondary)
                }
                Spacer()
                if isCheckingAuth {
                    ProgressView().controlSize(.small)
                } else {
                    Button("重新检查") {
                        Task { await checkCLIAndAuth() }
                    }
                    .buttonStyle(.dsGhost)
                }
            }

            if cliPath == nil && !isCheckingAuth {
                DSBanner(.warning, "未找到 `lark-cli`，请确认已安装或在「设置 → 月报 → lark-cli 路径」指定。")
            } else if let authStatus {
                if authStatus.isAvailable {
                    let who = authStatus.userName.isEmpty ? "当前用户" : authStatus.userName
                    DSBanner(.success, "已授权（\(who)），可执行飞书文档读取与覆盖写入。")
                } else {
                    let reason = authStatus.tokenStatus.isEmpty ? authStatus.status : authStatus.tokenStatus
                    DSBanner(.warning, "用户授权不可用（\(reason)）。请发起设备登录授权并在浏览器确认。")

                    HStack(spacing: 10) {
                        Button {
                            Task { await initiateDeviceLogin() }
                        } label: {
                            if isAuthorizing && deviceLogin == nil {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("发起设备登录授权")
                            }
                        }
                        .buttonStyle(.dsPrimary)
                        .disabled(isAuthorizing || cliPath == nil)

                        if let deviceLogin {
                            Button("在浏览器打开授权链接") {
                                if let url = URL(string: deviceLogin.verificationURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.dsSecondary)

                            Button {
                                Task { await finishDeviceLogin(deviceLogin.deviceCode) }
                            } label: {
                                if isAuthorizing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("我已完成授权，验证登录")
                                }
                            }
                            .buttonStyle(.dsPrimary)
                            .disabled(isAuthorizing)
                        }
                    }

                    if let deviceLogin {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("授权链接")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textSecondary)
                                if !deviceLogin.userCode.isEmpty {
                                    Tag("验证码 \(deviceLogin.userCode)", color: DS.brand)
                                }
                                Spacer()
                                Button("复制链接") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(deviceLogin.verificationURL, forType: .string)
                                }
                                .buttonStyle(.dsGhost)
                            }
                            Text(deviceLogin.verificationURL)
                                .font(DS.mono(11.5))
                                .foregroundStyle(DS.text)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .background(DS.well.opacity(0.6), in: .rect(cornerRadius: DS.controlRadius))
                    }
                }
            }
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }

    private var targetDocumentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("目标飞书文档链接")
                .font(DS.font(13.5, .semibold))

            TextField("粘贴飞书云文档或知识库 URL（例如 https://xxx.feishu.cn/wiki/...）", text: $docURLInput)
                .textFieldStyle(.ds)
                .onChange(of: docURLInput) { _, newValue in
                    model.feishuMonthlyDocURL = newValue
                }

            HStack(spacing: 10) {
                Button {
                    Task { await importChildWeeklyDocs() }
                } label: {
                    if isImportingChildren {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("读取下挂周报子文档导入补充说明", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.dsSecondary)
                .disabled(cliPath == nil || !isAuthorized || trimmedDocURL.isEmpty || isImportingChildren || isWritingDoc)

                Spacer()

                Text("待写入正文 \(model.formattedMarkdown().count) 字")
                    .font(DS.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.border) }
    }

    private func writeResultCard(_ result: FeishuDocWriteResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(DS.success)
                Text("写入并回读验证成功")
                    .font(DS.font(13.5, .semibold))
                Spacer()
                Text("回读 \(result.verifiedCharCount) 字")
                    .font(DS.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }
            if !result.verifiedTitle.isEmpty {
                Text("文档标题：\(result.verifiedTitle)")
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Text("目标链接：\(result.docURL)")
                .font(DS.mono(11.5))
                .foregroundStyle(DS.textSecondary)
                .textSelection(.enabled)
            if !result.preview.isEmpty {
                Text("回读摘要：\(result.preview)")
                    .font(DS.caption)
                    .foregroundStyle(DS.text)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .background(DS.success.opacity(0.08), in: .rect(cornerRadius: DS.radius))
        .overlay { RoundedRectangle(cornerRadius: DS.radius).strokeBorder(DS.success.opacity(0.3)) }
    }

    private var sheetFooter: some View {
        HStack(spacing: 10) {
            Button("关闭") {
                dismiss()
            }
            .buttonStyle(.dsGhost)
            .disabled(isWritingDoc || isImportingChildren)

            Spacer()

            Button {
                confirmOverwrite = true
            } label: {
                if isWritingDoc {
                    ProgressView().controlSize(.small)
                } else {
                    Text("覆盖写入飞书文档")
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(cliPath == nil || !isAuthorized || trimmedDocURL.isEmpty || !model.hasReportContent || isWritingDoc)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DS.sidebar)
    }

    private func checkCLIAndAuth() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }
        let resolved = await FeishuDocService.resolveCLIPath(configuredPath: model.feishuCLIPath)
        cliPath = resolved
        guard let resolved else {
            authStatus = nil
            return
        }
        do {
            authStatus = try await FeishuDocService.checkAuthStatus(cliPath: resolved)
        } catch {
            statusMessage = (.danger, error.localizedDescription)
        }
    }

    private func initiateDeviceLogin() async {
        guard let cliPath else { return }
        isAuthorizing = true
        statusMessage = nil
        defer { isAuthorizing = false }
        do {
            let info = try await FeishuDocService.startDeviceLogin(cliPath: cliPath)
            deviceLogin = info
            if let url = URL(string: info.verificationURL) {
                NSWorkspace.shared.open(url)
            }
            statusMessage = (.info, "已打开飞书授权页面，请在浏览器完成授权后点击「我已完成授权，验证登录」。")
        } catch {
            statusMessage = (.danger, error.localizedDescription)
        }
    }

    private func finishDeviceLogin(_ deviceCode: String) async {
        guard let cliPath else { return }
        isAuthorizing = true
        statusMessage = nil
        defer { isAuthorizing = false }
        do {
            let nextStatus = try await FeishuDocService.completeDeviceLogin(cliPath: cliPath, deviceCode: deviceCode)
            authStatus = nextStatus
            if nextStatus.isAvailable {
                deviceLogin = nil
                statusMessage = (.success, "飞书设备登录授权成功。")
            } else {
                statusMessage = (.warning, "尚未检测到有效用户授权，请确认已在浏览器点击同意。")
            }
        } catch {
            statusMessage = (.danger, error.localizedDescription)
        }
    }

    private func importChildWeeklyDocs() async {
        guard let cliPath else { return }
        let target = trimmedDocURL
        guard !target.isEmpty else { return }
        isImportingChildren = true
        statusMessage = nil
        defer { isImportingChildren = false }

        do {
            let children = try await FeishuDocService.fetchChildDocuments(cliPath: cliPath, parentDocURL: target)
            if children.isEmpty {
                let single = try await FeishuDocService.fetchDocumentMarkdown(cliPath: cliPath, docURL: target)
                let previewLen = single.markdown.count
                statusMessage = (.info, "该文档下未发现知识库子文档（当前目标文档共有 \(previewLen) 字）。")
                return
            }
            let parts: [String] = children.map { child in
                let heading = child.title.isEmpty ? "飞书子文档" : child.title
                return "### \(heading)\n\(child.markdown)"
            }
            let combined: String = parts.joined(separator: "\n\n")
            let existing = model.extraNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let updatedNotes: String = existing.isEmpty ? combined : "\(existing)\n\n\(combined)"
            model.extraNotes = updatedNotes
            model.saveEditsIfNeeded()
            statusMessage = (.success, "已读取 \(children.count) 份子周报文档并追加到「补充说明」，可重新生成月报。")
        } catch let err as FeishuCLIError {
            if case .authExpired = err {
                authStatus = FeishuAuthStatus(isAvailable: false, status: "expired", userName: authStatus?.userName ?? "", tokenStatus: "expired", hint: "")
            }
            statusMessage = (.danger, err.localizedDescription)
        } catch {
            statusMessage = (.danger, error.localizedDescription)
        }
    }

    private func performOverwrite() async {
        guard let cliPath else { return }
        let target = trimmedDocURL
        let markdown = model.formattedMarkdown()
        guard !target.isEmpty, !markdown.isEmpty else { return }

        model.saveEditsIfNeeded()
        model.feishuMonthlyDocURL = target
        isWritingDoc = true
        statusMessage = nil
        writeResult = nil
        defer { isWritingDoc = false }

        do {
            let result = try await FeishuDocService.overwriteDocument(
                cliPath: cliPath,
                docURL: target,
                markdown: markdown
            )
            writeResult = result
            model.message = "已将「\(model.activePeriodTitle)」\(model.periodKind.displayName)写入飞书文档并回读验证（\(result.verifiedCharCount) 字）"
        } catch let err as FeishuCLIError {
            if case .authExpired = err {
                authStatus = FeishuAuthStatus(isAvailable: false, status: "expired", userName: authStatus?.userName ?? "", tokenStatus: "expired", hint: "")
            }
            statusMessage = (.danger, err.localizedDescription)
        } catch {
            statusMessage = (.danger, error.localizedDescription)
        }
    }
}
