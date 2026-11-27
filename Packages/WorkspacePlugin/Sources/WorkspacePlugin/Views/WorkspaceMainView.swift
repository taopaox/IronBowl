import AppKit
import IronBowlKit
import SwiftUI

struct WorkspaceMainView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("代码仓库工作台", topPadding: 8) {
                HStack(spacing: 10) {
                    Text("\(model.repos.count) 个本地仓库")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.leading, sidebarCollapsed ? 38 : 0)
                }
            } actions: {
                Button {
                    addRepoFolder()
                } label: {
                    Label("添加仓库", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.dsSecondary)

                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.dsPrimary)
                .disabled(model.isRefreshing)
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let err = model.errorMessage {
                        DSBanner(.danger, err)
                    } else if let msg = model.statusMessage {
                        DSBanner(.success, msg)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        DSMetric("本地仓库", value: "\(model.repos.count) 个", detail: "与禅道日志共用根目录")
                        DSMetric(
                            "待提交 / 未推送",
                            value: "\(model.attentionCount) 个",
                            detail: model.attentionCount > 0 ? "下班前记得提交与 Push" : "所有仓库工作区干净",
                            valueColor: model.attentionCount > 0 ? DS.warning : DS.success
                        )
                        DSMetric("今日活跃", value: "\(model.todayActiveCount) 个", detail: "今天有本地 Git 提交")
                    }

                    HStack(spacing: 10) {
                        DSTabs(
                            selection: $model.filter,
                            options: WorkspaceFilter.allCases.map { ($0, $0.rawValue) }
                        )

                        Spacer()

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(DS.font(12))
                                .foregroundStyle(DS.textTertiary)
                            TextField("搜索仓库、分支、提交或禅道项目", text: $model.query)
                                .textFieldStyle(.plain)
                                .font(DS.body)
                            if !model.query.isEmpty {
                                Button { model.query = "" } label: {
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
                    }

                    if model.filteredRepos.isEmpty {
                        DSCard(padding: 28) {
                            VStack(spacing: 10) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(DS.font(28))
                                    .foregroundStyle(DS.textTertiary)
                                Text(model.repos.isEmpty ? "未扫描到 Git 仓库，可在设置中调整扫描目录或手动添加" : "没有符合当前筛选条件的仓库")
                                    .font(DS.body)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(model.filteredRepos) { repo in
                                repoCard(repo)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.canvas)
        }
        .task {
            if model.repos.isEmpty {
                await model.refresh()
            }
        }
    }

    private func repoCard(_ repo: WorkspaceRepoItem) -> some View {
        let installedEditors = ExternalEditorOption.installedOptions()
        return DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Button {
                        model.togglePin(repo.path)
                    } label: {
                        Image(systemName: repo.isPinned ? "star.fill" : "star")
                            .foregroundStyle(repo.isPinned ? DS.brand : DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(repo.isPinned ? "取消收藏" : "收藏置顶")

                    Text(repo.name)
                        .font(DS.font(15, .semibold))

                    badgeCapsule(repo.branch, icon: "arrow.triangle.branch", tint: DS.textSecondary)

                    if let project = repo.mappedProjectName {
                        badgeCapsule(project, icon: "link", tint: DS.brand)
                    }

                    if repo.isTodayActive {
                        badgeCapsule("今日活跃", icon: "flame.fill", tint: DS.success)
                    }

                    if repo.uncommittedCount > 0 {
                        badgeCapsule("未提交 \(repo.uncommittedCount)", icon: "pencil", tint: DS.warning)
                    }

                    if repo.unpushedCount > 0 {
                        badgeCapsule("未推 \(repo.unpushedCount)", icon: "arrow.up.circle.fill", tint: DS.danger)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        Button {
                            model.openInEditor(repo.path)
                        } label: {
                            Label("用编辑器打开", systemImage: "curlybraces.square")
                        }
                        .buttonStyle(.dsSecondary)

                        if installedEditors.count > 1 {
                            Menu {
                                ForEach(installedEditors) { ed in
                                    Button("在 \(ed.displayName) 中打开") {
                                        model.openInEditor(repo.path, editor: ed)
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(DS.font(11))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }

                        Button {
                            model.openChat(in: repo.path)
                        } label: {
                            Label("AI 对话", systemImage: "sparkles")
                        }
                        .buttonStyle(.dsSecondary)

                        Button {
                            model.openInTerminal(repo.path)
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .buttonStyle(.dsGhost)
                        .help("在终端打开")

                        Button {
                            model.revealInFinder(repo.path)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.dsGhost)
                        .help("在访达中显示")

                        Button {
                            Task { await model.fetchRepo(repo.path) }
                        } label: {
                            if model.fetchingRepoPath == repo.path {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.dsGhost)
                        .help("执行 git fetch --prune")
                        .disabled(model.fetchingRepoPath != nil)
                    }
                }

                HStack(spacing: 12) {
                    Text(repo.path)
                        .font(DS.mono(11.5))
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if !repo.lastCommitSubject.isEmpty {
                        Text("\(repo.lastCommitSubject)\(repo.lastCommitAuthor.isEmpty ? "" : " · \(repo.lastCommitAuthor)")")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func badgeCapsule(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(DS.font(10))
            Text(text)
                .font(DS.font(11, .medium).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.11), in: .capsule)
    }

    private func addRepoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加 Git 仓库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addExtraRepo(url.path)
    }
}

struct WorkspaceSettingsView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        DSSection("默认外部工具", footer: "选择「自动识别」时，将优先使用本机已安装的 Cursor / VS Code / Windsurf / Zed / Xcode 与 Ghostty / iTerm2 / Warp / 终端。") {
            DSRow("默认代码编辑器") {
                DSPicker(
                    selection: $model.defaultEditor,
                    options: ExternalEditorOption.allCases.map {
                        DSPickerOption($0, title: $0.displayName)
                    }
                )
            }
            DSRow("默认终端应用") {
                DSPicker(
                    selection: $model.defaultTerminal,
                    options: ExternalTerminalOption.allCases.map {
                        DSPickerOption($0, title: $0.displayName)
                    }
                )
            }
        }

        DSSection("额外纳管仓库", footer: "除禅道日志扫描目录之外，额外手动纳管的仓库路径。") {
            if model.extraRepos.isEmpty {
                DSRow("暂无额外仓库") {
                    Button("添加目录…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            model.addExtraRepo(url.path)
                        }
                    }
                    .buttonStyle(.dsSecondary)
                }
            } else {
                ForEach(model.extraRepos, id: \.self) { path in
                    DSRow((path as NSString).lastPathComponent, description: path) {
                        Button("移除", role: .destructive) {
                            model.removeExtraRepo(path)
                        }
                        .buttonStyle(.dsGhost)
                    }
                }
            }
        }
    }
}
