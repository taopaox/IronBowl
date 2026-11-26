import AppKit
import IronBowlKit
import SwiftUI

/// 首页「今天」页面内的可折叠多对话列表栏（T3 Code Threads 风格）。
struct HomeChatSidebar: View {
    let app: AppModel
    let onNewDraft: () -> Void

    @Environment(\.sidebarCollapsed) private var mainSidebarCollapsed
    @State private var searchText = ""
    @State private var renamingThread: ChatThread?
    @State private var renameText = ""

    private var filteredThreads: [ChatThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return app.chat.threads }
        return app.chat.threads.filter {
            $0.title.lowercased().contains(query)
                || $0.workspaceName.lowercased().contains(query)
                || $0.providerKind.rawValue.lowercased().contains(query)
        }
    }

    private var groupedSections: [(title: String, items: [ChatThread])] {
        let pinned = filteredThreads.filter(\.isPinned)
        let regular = filteredThreads.filter { !$0.isPinned }
        let cal = Calendar.current

        var todayItems: [ChatThread] = []
        var yesterdayItems: [ChatThread] = []
        var earlierItems: [ChatThread] = []

        for thread in regular {
            if cal.isDateInToday(thread.updatedAt) {
                todayItems.append(thread)
            } else if cal.isDateInYesterday(thread.updatedAt) {
                yesterdayItems.append(thread)
            } else {
                earlierItems.append(thread)
            }
        }

        var sections: [(String, [ChatThread])] = []
        if !pinned.isEmpty { sections.append(("置顶", pinned)) }
        if !todayItems.isEmpty { sections.append(("今天", todayItems)) }
        if !yesterdayItems.isEmpty { sections.append(("昨天", yesterdayItems)) }
        if !earlierItems.isEmpty { sections.append(("更早", earlierItems)) }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !mainSidebarCollapsed {
                    Text("对话")
                        .font(DS.font(14, .semibold))
                        .foregroundStyle(DS.text)
                }
                Spacer(minLength: 4)
                Button(action: onNewDraft) {
                    Image(systemName: "square.and.pencil")
                        .font(DS.font(13.5))
                }
                .buttonStyle(.dsGhost)
                .help("新建对话")

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        app.chat.sidebarCollapsed = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(DS.font(13.5))
                }
                .buttonStyle(.dsGhost)
                .help("收起对话列表")
            }
            .padding(.leading, mainSidebarCollapsed ? 116 : 12)
            .padding(.trailing, 8)
            .frame(height: 52)
            .windowTitleBar()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(12))
                    .foregroundStyle(DS.textTertiary)
                TextField("搜索对话或目录…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.font(13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: DS.s(28))
            .background(DS.card, in: .rect(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(DS.border) }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if filteredThreads.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 24)
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(DS.font(24))
                        .foregroundStyle(DS.textTertiary)
                    Text(app.chat.threads.isEmpty ? "还没有对话" : "没有匹配的对话")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    if app.chat.threads.isEmpty {
                        Button("开始第一条对话", action: onNewDraft)
                            .buttonStyle(.dsSecondary)
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groupedSections, id: \.title) { section in
                            Text(section.title)
                                .font(DS.font(11.5, .medium))
                                .foregroundStyle(DS.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                                .padding(.bottom, 3)

                            ForEach(section.items) { thread in
                                ThreadSidebarRow(
                                    thread: thread,
                                    selected: app.chat.selectedThreadID == thread.id,
                                    isRunning: app.chat.isRunning(thread.id),
                                    onSelect: { app.chat.selectThread(thread.id) },
                                    onStartRename: {
                                        renameText = thread.title
                                        renamingThread = thread
                                    },
                                    onTogglePin: { app.chat.togglePinThread(thread.id) },
                                    onRevealWorkspace: {
                                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: thread.workspacePath)
                                    },
                                    onDelete: { app.chat.deleteThread(thread.id) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
        }
        .background(DS.sidebar.opacity(0.65))
        .sheet(item: $renamingThread) { thread in
            VStack(alignment: .leading, spacing: 14) {
                Text("重命名对话").font(DS.sectionTitle)
                TextField("对话标题", text: $renameText)
                    .textFieldStyle(.ds)
                    .onSubmit {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { app.chat.renameThread(thread.id, title: trimmed) }
                        renamingThread = nil
                    }
                HStack {
                    Spacer()
                    Button("取消") { renamingThread = nil }.buttonStyle(.dsSecondary)
                    Button("保存") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { app.chat.renameThread(thread.id, title: trimmed) }
                        renamingThread = nil
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(18)
            .frame(width: DS.s(320))
            .background(DS.card)
        }
    }
}

private struct ThreadSidebarRow: View {
    let thread: ChatThread
    let selected: Bool
    let isRunning: Bool
    let onSelect: () -> Void
    let onStartRename: () -> Void
    let onTogglePin: () -> Void
    let onRevealWorkspace: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var relativeTimeText: String {
        if Calendar.current.isDateInToday(thread.updatedAt) {
            return CN.time(thread.updatedAt)
        }
        return CN.slash(thread.updatedAt)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 12, height: 12)
                        } else if thread.isPinned {
                            Image(systemName: "pin.fill")
                                .font(DS.font(10))
                                .foregroundStyle(DS.brand)
                        }
                        Text(thread.title)
                            .font(DS.font(13, selected ? .semibold : .medium))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }

                    HStack(spacing: 4) {
                        Text(thread.workspaceName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·")
                        Text(thread.providerKind.rawValue)
                        Spacer(minLength: 4)
                        Text(relativeTimeText)
                            .monospacedDigit()
                    }
                    .font(DS.font(11))
                    .foregroundStyle(DS.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if hovering {
                Menu {
                    menuItems()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? DS.selected : hovering ? DS.hover : .clear, in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu { menuItems() }
    }

    @ViewBuilder
    private func menuItems() -> some View {
        Button("重命名…", action: onStartRename)
        Button(thread.isPinned ? "取消置顶" : "置顶对话", action: onTogglePin)
        Button("在 Finder 中打开工作目录", action: onRevealWorkspace)
        Divider()
        Button("删除对话", role: .destructive, action: onDelete)
    }
}
