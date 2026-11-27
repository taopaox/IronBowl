import AppKit
import IronBowlKit
import SwiftUI

struct DevToolsMainView: View {
    @Bindable var model: DevToolsModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    enum ToolTab: String, CaseIterable, Hashable {
        case ports = "端口管家"
        case timestamp = "时间戳"
        case jwt = "JWT 解析"
        case codec = "编解码与哈希"
        case diff = "文本对比"
    }

    @State private var activeTab: ToolTab = .ports

    // 时间戳
    @State private var tsInput = String(Int64(Date().timeIntervalSince1970))
    @State private var dateInput = ""

    // JWT
    @State private var jwtInput = ""

    // 编解码
    @State private var codecInput = ""
    @State private var codecOutput = ""
    @State private var codecError: String?
    @State private var uuidUppercase = false
    @State private var uuids: [String] = DevConverters.generateUUIDs()

    // Diff
    @State private var diffLeft = ""
    @State private var diffRight = ""
    @State private var diffPrettyJSON = false

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("研发工具箱", topPadding: 8) {
                DSTabs(
                    selection: $activeTab,
                    options: ToolTab.allCases.map { ($0, $0.rawValue) }
                )
                .padding(.leading, sidebarCollapsed ? 38 : 0)
            } actions: {
                if activeTab == .ports {
                    Button {
                        Task { await model.refreshPorts() }
                    } label: {
                        if model.isScanningPorts {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("刷新端口", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(model.isScanningPorts)
                }
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch activeTab {
                    case .ports:
                        portsPane
                    case .timestamp:
                        timestampPane
                    case .jwt:
                        jwtPane
                    case .codec:
                        codecPane
                    case .diff:
                        diffPane
                    }
                }
                .padding(24)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.canvas)
        }
        .task {
            if model.ports.isEmpty {
                await model.refreshPorts()
            }
        }
    }

    // MARK: - 端口管家

    private var portsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = model.portErrorMessage {
                DSBanner(.danger, err)
            } else if let msg = model.portStatusMessage {
                DSBanner(.success, msg)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textTertiary)
                    TextField("搜索端口号、进程名、PID 或命令行", text: $model.portQuery)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                    if !model.portQuery.isEmpty {
                        Button { model.portQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DS.font(12))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: DS.s(290), height: DS.s(30))
                .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }

                ForEach(model.watchedPorts, id: \.self) { port in
                    Button(":\(port)") {
                        model.portQuery = "\(port)"
                    }
                    .buttonStyle(.dsChip(selected: model.portQuery == "\(port)"))
                }

                Spacer()
                Text("共 \(model.filteredPorts.count) 项监听")
                    .font(DS.caption.monospacedDigit())
                    .foregroundStyle(DS.textSecondary)
            }

            if model.filteredPorts.isEmpty {
                DSCard(padding: 24) {
                    Text("没有匹配的 TCP 监听端口")
                        .font(DS.body)
                        .foregroundStyle(DS.textSecondary)
                        .frame(maxWidth: .infinity)
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.filteredPorts) { item in
                        DSCard(padding: 12) {
                            HStack(spacing: 12) {
                                Text(":\(item.port)")
                                    .font(DS.font(16, .bold).monospacedDigit())
                                    .foregroundStyle(model.watchedPorts.contains(item.port) ? DS.brand : DS.text)
                                    .frame(width: DS.s(76), alignment: .leading)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(item.processName)
                                            .font(DS.font(14, .semibold))
                                        Text("PID \(item.pid)")
                                            .font(DS.caption.monospacedDigit())
                                            .foregroundStyle(DS.textSecondary)
                                        Text(item.bindAddress)
                                            .font(DS.mono(11.5))
                                            .foregroundStyle(DS.textTertiary)
                                    }
                                    if !item.commandLine.isEmpty {
                                        Text(item.commandLine)
                                            .font(DS.mono(11.5))
                                            .foregroundStyle(DS.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                }

                                Spacer(minLength: 8)

                                Button("结束 (TERM)") {
                                    Task { await model.killPort(item, force: false) }
                                }
                                .buttonStyle(.dsSecondary)

                                Button("强杀 (KILL)") {
                                    Task { await model.killPort(item, force: true) }
                                }
                                .buttonStyle(.dsGhost)
                                .foregroundStyle(DS.danger)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 时间戳

    private var timestampPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("时间戳 → 日期时间")
                            .font(DS.sectionTitle)
                        Spacer()
                        Button("当前时间戳 (s)") {
                            tsInput = String(Int64(Date().timeIntervalSince1970))
                        }
                        .buttonStyle(.dsSecondary)
                        Button("当前时间戳 (ms)") {
                            tsInput = String(Int64(Date().timeIntervalSince1970 * 1000))
                        }
                        .buttonStyle(.dsSecondary)
                    }

                    TextField("输入 10 位秒或 13 位毫秒时间戳", text: $tsInput)
                        .textFieldStyle(.ds)
                        .font(DS.mono(14))

                    if let info = DevConverters.parseTimestamp(tsInput) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            DSMetric("识别单位", value: info.unitLabel)
                            DSMetric("本地时间", value: info.localText)
                            DSMetric("UTC 时间", value: info.utcText)
                            DSMetric("ISO 8601", value: info.iso8601Text)
                        }
                    } else {
                        Text("请输入有效的数字时间戳")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }

            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("日期时间 → 时间戳")
                        .font(DS.sectionTitle)
                    TextField("例如：2026-11-27 14:30:00 或 2026-11-27", text: $dateInput)
                        .textFieldStyle(.ds)
                        .font(DS.mono(14))

                    if let info = DevConverters.dateStringToTimestamp(dateInput) {
                        HStack(spacing: 12) {
                            DSMetric("秒 (s)", value: "\(info.seconds)")
                            DSMetric("毫秒 (ms)", value: "\(info.milliseconds)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - JWT 解析

    private var jwtPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("输入 JWT Token（支持带 Bearer 前缀，纯离线本地解码）")
                            .font(DS.sectionTitle)
                        Spacer()
                        Button("粘贴") {
                            jwtInput = NSPasteboard.general.string(forType: .string) ?? ""
                        }
                        .buttonStyle(.dsSecondary)
                        Button("清空") { jwtInput = "" }
                            .buttonStyle(.dsGhost)
                    }
                    TextEditor(text: $jwtInput)
                        .font(DS.mono(12.5))
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .padding(8)
                        .background(DS.well, in: .rect(cornerRadius: 8))
                }
            }

            if let decoded = DevConverters.decodeJWT(jwtInput) {
                HStack(spacing: 12) {
                    DSMetric(
                        "过期状态",
                        value: decoded.expiryStatusText,
                        valueColor: decoded.isExpired == true ? DS.danger : (decoded.isExpired == false ? DS.success : DS.text)
                    )
                    DSMetric("签发时间 (iat)", value: decoded.issuedAtText ?? "—")
                    DSMetric("过期时间 (exp)", value: decoded.expiresAtText ?? "—")
                }

                HStack(alignment: .top, spacing: 14) {
                    DSCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Header")
                                .font(DS.sectionTitle)
                            Text(decoded.headerJSON)
                                .font(DS.mono(12.5))
                                .textSelection(.enabled)
                        }
                    }
                    DSCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Payload")
                                .font(DS.sectionTitle)
                            Text(decoded.payloadJSON)
                                .font(DS.mono(12.5))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if !jwtInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DSBanner(.warning, "无法识别为合法的 JWT 结构（需包含由 `.` 分隔的 Base64URL Header 与 Payload）。")
            }
        }
    }

    // MARK: - 编解码与哈希

    private var codecPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("输入原文")
                        .font(DS.sectionTitle)
                    TextEditor(text: $codecInput)
                        .font(DS.mono(13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 110)
                        .padding(8)
                        .background(DS.well, in: .rect(cornerRadius: 8))

                    HStack(spacing: 8) {
                        Button("Base64 编码") { codecError = nil; codecOutput = DevConverters.base64Encode(codecInput) }.buttonStyle(.dsSecondary)
                        Button("Base64 解码") {
                            if let d = DevConverters.base64Decode(codecInput) { codecError = nil; codecOutput = d }
                            else { codecError = "Base64 解码失败，请检查输入格式。" }
                        }.buttonStyle(.dsSecondary)
                        Button("URL 编码") { codecError = nil; codecOutput = DevConverters.urlEncode(codecInput) }.buttonStyle(.dsSecondary)
                        Button("URL 解码") {
                            if let d = DevConverters.urlDecode(codecInput) { codecError = nil; codecOutput = d }
                            else { codecError = "URL 解码失败。" }
                        }.buttonStyle(.dsSecondary)
                        Button("\\u 转中文") { codecError = nil; codecOutput = DevConverters.unicodeUnescape(codecInput) }.buttonStyle(.dsSecondary)
                        Button("中文转 \\u") { codecError = nil; codecOutput = DevConverters.unicodeEscape(codecInput) }.buttonStyle(.dsSecondary)
                        Button("SHA256") { codecError = nil; codecOutput = DevConverters.sha256(codecInput) }.buttonStyle(.dsSecondary)
                        Button("MD5") { codecError = nil; codecOutput = DevConverters.md5(codecInput) }.buttonStyle(.dsSecondary)
                    }

                    if let codecError {
                        DSBanner(.danger, codecError)
                    }

                    HStack {
                        Text("输出结果")
                            .font(DS.sectionTitle)
                        Spacer()
                        Button("复制结果") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(codecOutput, forType: .string)
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(codecOutput.isEmpty)
                    }
                    TextEditor(text: .constant(codecOutput))
                        .font(DS.mono(13))
                        .scrollContentBackground(.hidden)
                        .frame(height: 110)
                        .padding(8)
                        .background(DS.well, in: .rect(cornerRadius: 8))
                }
            }

            DSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("UUID v4 生成器")
                            .font(DS.sectionTitle)
                        Spacer()
                        Toggle("大写", isOn: $uuidUppercase)
                            .toggleStyle(.checkbox)
                            .font(DS.caption)
                        Button("重新生成") {
                            uuids = DevConverters.generateUUIDs(count: 5, uppercase: uuidUppercase)
                        }
                        .buttonStyle(.dsSecondary)
                    }
                    Text(uuids.joined(separator: "\n"))
                        .font(DS.mono(12.5))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 文本 Diff

    private var diffPane: some View {
        let lines = DevConverters.computeLineDiff(left: diffLeft, right: diffRight, prettyJSON: diffPrettyJSON)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("对比前自动美化两侧 JSON", isOn: $diffPrettyJSON)
                    .toggleStyle(.checkbox)
                    .font(DS.caption)
                Spacer()
                Button("交换左右") {
                    let tmp = diffLeft
                    diffLeft = diffRight
                    diffRight = tmp
                }
                .buttonStyle(.dsSecondary)
                Button("清空") {
                    diffLeft = ""
                    diffRight = ""
                }
                .buttonStyle(.dsGhost)
            }

            HStack(spacing: 12) {
                DSCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原始文本（左）").font(DS.caption).foregroundStyle(DS.textSecondary)
                        TextEditor(text: $diffLeft)
                            .font(DS.mono(12.5))
                            .scrollContentBackground(.hidden)
                            .frame(height: 160)
                    }
                }
                DSCard(padding: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标文本（右）").font(DS.caption).foregroundStyle(DS.textSecondary)
                        TextEditor(text: $diffRight)
                            .font(DS.mono(12.5))
                            .scrollContentBackground(.hidden)
                            .frame(height: 160)
                    }
                }
            }

            DSCard(padding: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("行级差异对比")
                        .font(DS.sectionTitle)
                        .padding(.bottom, 6)
                    ForEach(lines) { line in
                        HStack(spacing: 8) {
                            Text(line.kind == .removed ? "-" : (line.kind == .added ? "+" : " "))
                                .font(DS.mono(12))
                                .foregroundStyle(line.kind == .removed ? DS.danger : (line.kind == .added ? DS.success : DS.textTertiary))
                                .frame(width: 14)
                            Text(line.text)
                                .font(DS.mono(12.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            line.kind == .removed ? DS.danger.opacity(0.09)
                                : (line.kind == .added ? DS.success.opacity(0.09) : .clear),
                            in: .rect(cornerRadius: 4)
                        )
                    }
                }
            }
        }
    }
}
