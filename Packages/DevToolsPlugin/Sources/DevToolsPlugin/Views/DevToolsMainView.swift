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
    @State private var showDevGroupExpanded = true
    @State private var showOtherGroupExpanded = true
    @State private var showDirectoryPopover = false

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
        let partition = model.filteredPartition
        let devEntries = model.effectiveDevDirectoryEntries

        return VStack(alignment: .leading, spacing: 14) {
            if let err = model.portErrorMessage {
                DSBanner(.danger, err)
            } else if let msg = model.portStatusMessage {
                DSBanner(.success, msg)
            }

            HStack(spacing: 10) {
                DSTabs(
                    selection: $model.portGroupScope,
                    options: [
                        (.all, "全部分组 (\(partition.totalCount))"),
                        (.devDirectory, "我的开发目录 (\(partition.devDirectoryItems.count))"),
                        (.other, "其他端口 (\(partition.otherItems.count))"),
                    ]
                )

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(12))
                        .foregroundStyle(DS.textTertiary)
                    TextField("搜索端口、进程、目录、PID 或命令行", text: $model.portQuery)
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
                .frame(width: DS.s(260), height: DS.s(30))
                .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }

                Button {
                    showDirectoryPopover.toggle()
                } label: {
                    Label("开发目录", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.dsSecondary)
                .popover(isPresented: $showDirectoryPopover, arrowEdge: .bottom) {
                    devDirectoryPopoverContent(devEntries)
                }
            }

            HStack(spacing: 8) {
                ForEach(model.watchedPorts, id: \.self) { port in
                    let isSelected = model.portQuery == "\(port)"
                    Button(":\(port)") {
                        model.portQuery = isSelected ? "" : "\(port)"
                    }
                    .buttonStyle(.dsChip(selected: isSelected))
                }

                Spacer(minLength: 8)

                Text(directorySummaryText(devEntries))
                    .font(DS.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }

            if model.portGroupScope == .all || model.portGroupScope == .devDirectory {
                devDirectorySection(partition: partition, devEntries: devEntries)
            }

            if model.portGroupScope == .all || model.portGroupScope == .other {
                otherPortsSection(partition: partition)
            }
        }
    }

    private func directorySummaryText(_ entries: [DevDirectoryEntry]) -> String {
        guard let first = entries.first else { return "未配置开发目录" }
        if entries.count == 1 {
            return "监控目录：\(first.displayName)"
        }
        return "监控目录：\(first.displayName) 等 \(entries.count) 个"
    }

    @ViewBuilder
    private func devDirectorySection(partition: PortPartition, devEntries: [DevDirectoryEntry]) -> some View {
        let items = partition.devDirectoryItems
        let uniqueProjectCount = Set(items.compactMap { $0.directoryMatch?.projectLabel }).count
        let isAllScope = model.portGroupScope == .all

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    if isAllScope { showDevGroupExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if isAllScope {
                            Image(systemName: showDevGroupExpanded ? "chevron.down" : "chevron.right")
                                .font(DS.font(11, .semibold))
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: 12)
                        }
                        Image(systemName: "folder.fill")
                            .font(DS.font(13))
                            .foregroundStyle(DS.success)
                        Text("我的开发目录")
                            .font(DS.sectionTitle)
                            .foregroundStyle(DS.text)
                    }
                }
                .buttonStyle(.plain)

                countCapsule("\(items.count) 项监听", tint: items.isEmpty ? DS.textSecondary : DS.success)

                if uniqueProjectCount > 0 {
                    countCapsule("\(uniqueProjectCount) 个项目", tint: DS.brand)
                }

                Spacer()

                Button {
                    pickAndAddDevDirectory()
                } label: {
                    Label("添加目录", systemImage: "plus")
                }
                .buttonStyle(.dsGhost)
            }

            if !isAllScope || showDevGroupExpanded {
                if devEntries.isEmpty {
                    DSCard(padding: 18, dashed: true) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus")
                                .font(DS.font(20))
                                .foregroundStyle(DS.textTertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("尚未配置开发目录")
                                    .font(DS.rowTitle)
                                Text("自动读取禅道日志根目录与代码仓库配置，也可以手动添加本地项目目录进行端口隔离检查。")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            Spacer()
                            Button("添加开发目录…") {
                                pickAndAddDevDirectory()
                            }
                            .buttonStyle(.dsSecondary)
                        }
                    }
                } else if items.isEmpty {
                    DSCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.portQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "当前开发目录下暂无匹配的 TCP 监听端口"
                                : "当前开发目录下没有符合搜索条件的监听端口")
                                .font(DS.body)
                                .foregroundStyle(DS.textSecondary)
                            Text("已纳管目录：\(devEntries.map(\.path).joined(separator: " · "))")
                                .font(DS.mono(11.5))
                                .foregroundStyle(DS.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { entry in
                            portRowCard(entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func otherPortsSection(partition: PortPartition) -> some View {
        let items = partition.otherItems
        let isAllScope = model.portGroupScope == .all

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    if isAllScope { showOtherGroupExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if isAllScope {
                            Image(systemName: showOtherGroupExpanded ? "chevron.down" : "chevron.right")
                                .font(DS.font(11, .semibold))
                                .foregroundStyle(DS.textSecondary)
                                .frame(width: 12)
                        }
                        Image(systemName: "network")
                            .font(DS.font(13))
                            .foregroundStyle(DS.textSecondary)
                        Text("其他监听端口")
                            .font(DS.sectionTitle)
                            .foregroundStyle(DS.text)
                    }
                }
                .buttonStyle(.plain)

                countCapsule("\(items.count) 项", tint: DS.textSecondary)

                Spacer()
            }

            if !isAllScope || showOtherGroupExpanded {
                if items.isEmpty {
                    DSCard(padding: 16) {
                        Text("没有其他匹配的 TCP 监听端口")
                            .font(DS.body)
                            .foregroundStyle(DS.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { entry in
                            portRowCard(entry)
                        }
                    }
                }
            }
        }
    }

    private func portRowCard(_ entry: GroupedListeningPort) -> some View {
        let item = entry.item
        let match = entry.directoryMatch
        let isWatched = model.watchedPorts.contains(item.port)
        let portColor = isWatched ? DS.brand : (match != nil ? DS.success : DS.text)
        let revealPath: String? = {
            if let dir = match?.matchedDirectory, !dir.isEmpty { return dir }
            if !item.workingDirectory.isEmpty, item.workingDirectory != "/" { return item.workingDirectory }
            return nil
        }()

        return DSCard(padding: 12) {
            HStack(spacing: 12) {
                Text(":\(item.port)")
                    .font(DS.font(16, .bold).monospacedDigit())
                    .foregroundStyle(portColor)
                    .frame(width: DS.s(76), alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.processName)
                            .font(DS.font(14, .semibold))
                        Text("PID \(item.pid)")
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                        Text(item.bindAddress)
                            .font(DS.mono(11.5))
                            .foregroundStyle(DS.textTertiary)

                        if let match {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(DS.font(10))
                                Text(match.projectLabel)
                                    .font(DS.font(11, .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(DS.success)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.success.opacity(0.12), in: .capsule)
                            .help("命中开发目录（\(match.basis.displayLabel)）：\(match.matchedDirectory)")
                        }
                    }

                    let secondaryLine = !item.commandLine.isEmpty
                        ? item.commandLine
                        : (match?.matchedDirectory ?? "")
                    if !secondaryLine.isEmpty {
                        Text(secondaryLine)
                            .font(DS.mono(11.5))
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 8)

                if let revealPath {
                    Button {
                        model.revealDirectory(revealPath)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.dsGhost)
                    .help("在访达中打开目录：\(revealPath)")
                }

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

    private func countCapsule(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(DS.font(11, .medium).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: .capsule)
    }

    private func devDirectoryPopoverContent(_ entries: [DevDirectoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我的开发目录")
                    .font(DS.sectionTitle)
                Spacer()
                Button("仓库设置") {
                    showDirectoryPopover = false
                    model.openRepoRootSettings()
                }
                .buttonStyle(.dsGhost)
                .font(DS.caption)
            }

            Text("自动同步「仓库根目录」与「额外仓库」，也可单独添加本地开发目录。")
                .font(DS.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if entries.isEmpty {
                Text("暂无有效开发目录")
                    .font(DS.caption)
                    .foregroundStyle(DS.textTertiary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.displayName)
                                            .font(DS.font(13, .medium))
                                        countCapsule(
                                            entry.source.displayLabel,
                                            tint: entry.source == .custom ? DS.brand : DS.textSecondary
                                        )
                                    }
                                    Text(entry.path)
                                        .font(DS.mono(11))
                                        .foregroundStyle(DS.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                if entry.source == .custom {
                                    Button {
                                        model.removeDevDirectory(entry.path)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(DS.danger)
                                    }
                                    .buttonStyle(.dsGhost)
                                    .help("移除此自定义目录")
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider()

            HStack {
                Button {
                    showDirectoryPopover = false
                    pickAndAddDevDirectory()
                } label: {
                    Label("添加开发目录…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.dsSecondary)

                Spacer()
            }
        }
        .padding(14)
        .frame(width: 390)
    }

    private func pickAndAddDevDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "设为开发目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addDevDirectory(url.path)
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

struct DevToolsSettingsView: View {
    @Bindable var model: DevToolsModel
    @State private var portsInput = ""
    @State private var portsNotice: String?

    var body: some View {
        let syncedEntries = model.effectiveDevDirectoryEntries.filter { $0.source != .custom }
        let customEntries = model.effectiveDevDirectoryEntries.filter { $0.source == .custom }

        DSSection("我的开发目录", footer: "端口管家会自动识别工作目录或启动命令命中以下目录的本地监听进程，并归入「我的开发目录」分组。") {
            if syncedEntries.isEmpty {
                DSRow("同步目录", description: "暂未配置禅道仓库根目录或额外仓库") {
                    Button("前往仓库设置") {
                        model.openRepoRootSettings()
                    }
                    .buttonStyle(.dsSecondary)
                }
            } else {
                ForEach(syncedEntries) { entry in
                    DSRow("\(entry.displayName)（\(entry.source.displayLabel)）", description: entry.path) {
                        if entry.source == .gitRoot {
                            Button("仓库设置") {
                                model.openRepoRootSettings()
                            }
                            .buttonStyle(.dsGhost)
                        } else {
                            Button("访达") {
                                model.revealDirectory(entry.path)
                            }
                            .buttonStyle(.dsGhost)
                        }
                    }
                }
            }

            ForEach(customEntries) { entry in
                DSRow("\(entry.displayName)（自定义）", description: entry.path) {
                    Button("移除", role: .destructive) {
                        model.removeDevDirectory(entry.path)
                    }
                    .buttonStyle(.dsGhost)
                }
            }

            DSRow("添加开发目录", description: "追加除仓库根目录之外常驻运行服务的代码目录。") {
                Button("选择目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "添加开发目录"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    model.addDevDirectory(url.path)
                }
                .buttonStyle(.dsSecondary)
            }
        }

        DSSection("常用关注端口", footer: "逗号分隔端口号（1–65535），将在端口管家顶部显示快捷筛选胶囊并在菜单栏统计活跃数。") {
            DSBlockRow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("例如：3000, 5173, 8000, 8080, 8888", text: $portsInput)
                            .textFieldStyle(.ds)
                            .font(DS.mono(13))
                        Button("保存") {
                            saveWatchedPorts()
                        }
                        .buttonStyle(.dsPrimary)
                        Button("恢复默认") {
                            let defaults = DevToolsKeys.watchedPorts.defaultValue
                            model.watchedPorts = defaults
                            portsInput = defaults.map(String.init).joined(separator: ", ")
                            portsNotice = "已恢复默认关注端口"
                        }
                        .buttonStyle(.dsSecondary)
                    }
                    if let portsNotice {
                        Text(portsNotice)
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
            }
        }
        .onAppear {
            if portsInput.isEmpty {
                portsInput = model.watchedPorts.map(String.init).joined(separator: ", ")
            }
        }
    }

    private func saveWatchedPorts() {
        let parts = portsInput.split { $0 == "," || $0 == "，" || $0.isWhitespace }
        var seen = Set<Int>()
        var parsed: [Int] = []
        for raw in parts {
            if let port = Int(raw), (1...65535).contains(port), seen.insert(port).inserted {
                parsed.append(port)
            }
        }
        guard !parsed.isEmpty else {
            portsNotice = "请输入至少一个有效的端口号（1–65535）"
            return
        }
        let sorted = parsed.sorted()
        model.watchedPorts = sorted
        portsInput = sorted.map(String.init).joined(separator: ", ")
        portsNotice = "已保存 \(sorted.count) 个常用关注端口"
    }
}
