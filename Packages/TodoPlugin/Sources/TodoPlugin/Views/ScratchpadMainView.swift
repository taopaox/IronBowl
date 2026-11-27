import AppKit
import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

struct ScratchpadMainView: View {
    let context: PluginContext
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed
    @Environment(\.isPageActive) private var isPageActive

    enum SectionTab: String, CaseIterable, Hashable {
        case notes = "便签笔记"
        case clipboard = "剪贴板历史"
        case snippets = "常用片段"
    }

    enum ViewMode: Hashable {
        case edit
        case preview
    }

    @State private var activeTab: SectionTab = .notes
    @State private var selectedNoteID: String?
    @State private var selectedClipboardID: String?
    @State private var selectedSnippetID: String?
    @State private var query = ""
    @State private var clipQuery = ""
    @State private var clipKindFilter: ClipboardContentKind?
    @State private var filterTag: ScratchpadColorTag?
    @State private var viewMode: ViewMode = .edit
    @State private var draftTitle = ""
    @State private var draftContent = ""
    @State private var draftTag: ScratchpadColorTag = .amber
    @State private var draftPinned = false
    @State private var snippetTitleDraft = ""
    @State private var snippetContentDraft = ""
    @State private var confirmClearHistory = false
    @State private var feedback: (isError: Bool, text: String)?
    @State private var saveTask: Task<Void, Never>?

    private var store: ScratchpadStore { context.scratchpad }
    private var clipboardStore: ClipboardHistoryStore { context.clipboard }

    private var filteredNotes: [ScratchpadNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.notes.filter { note in
            if let filterTag, note.tag != filterTag { return false }
            if !q.isEmpty {
                let hitTitle = note.displayTitle.localizedCaseInsensitiveContains(q)
                let hitBody = note.content.localizedCaseInsensitiveContains(q)
                if !hitTitle && !hitBody { return false }
            }
            return true
        }
    }

    private var selectedNote: ScratchpadNote? {
        guard let selectedNoteID else { return nil }
        return store.notes.first { $0.id == selectedNoteID }
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("随手便签", topPadding: 8) {
                HStack(spacing: 10) {
                    DSTabs(
                        selection: $activeTab,
                        options: SectionTab.allCases.map { ($0, $0.rawValue) }
                    )
                    .padding(.leading, sidebarCollapsed ? 38 : 0)

                    Text(headerSubtitle)
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            } actions: {
                switch activeTab {
                case .notes:
                    Button {
                        createFromClipboard()
                    } label: {
                        Label("粘入剪贴板", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.dsSecondary)

                    Button {
                        createNewNote()
                    } label: {
                        Label("新建便签", systemImage: "plus")
                    }
                    .buttonStyle(.dsPrimary)

                case .clipboard:
                    if !clipboardStore.historyItems.isEmpty {
                        Button("清空历史", role: .destructive) {
                            confirmClearHistory = true
                        }
                        .buttonStyle(.dsSecondary)
                    }
                case .snippets:
                    Button {
                        createNewSnippet()
                    } label: {
                        Label("新建片段", systemImage: "plus")
                    }
                    .buttonStyle(.dsPrimary)
                }
            }

            Divider().overlay(DS.border)

            switch activeTab {
            case .notes:
                HStack(spacing: 0) {
                    leftListPane
                        .frame(width: DS.s(268))
                        .background(DS.sidebar)

                    Rectangle().fill(DS.border).frame(width: 1)

                    rightEditorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.canvas)
                }
            case .clipboard:
                clipboardHistorySplitPane
            case .snippets:
                snippetsSplitPane
            }
        }
        .onAppear {
            if selectedNoteID == nil {
                selectNote(store.notes.first)
            }
            if selectedClipboardID == nil {
                selectedClipboardID = clipboardStore.historyItems.first?.id
            }
            if selectedSnippetID == nil {
                selectSnippet(clipboardStore.snippetItems.first)
            }
        }
        .onChange(of: isPageActive) { _, active in
            if !active {
                flushSave()
            }
        }
        .onDisappear {
            flushSave()
        }
        .alert("清空剪贴板历史？", isPresented: $confirmClearHistory) {
            Button("清空历史", role: .destructive) {
                clipboardStore.clearHistoryKeepingSnippets()
                selectedClipboardID = nil
                feedback = (false, "已清空剪贴板历史（已保留常用片段）")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空所有非「常用片段」的剪贴板历史记录，常用片段不受影响。")
        }
    }

    private var headerSubtitle: String {
        switch activeTab {
        case .notes: "\(store.notes.count) 条便签"
        case .clipboard: "\(clipboardStore.historyItems.count) 条历史"
        case .snippets: "\(clipboardStore.snippetItems.count) 个片段"
        }
    }

    // MARK: - 左侧列表

    private var leftListPane: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.textTertiary)
                TextField("搜索便签标题或内容", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.font(12))
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: DS.s(30))
            .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
            .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 6) {
                tagFilterDot(nil, label: "全部")
                ForEach(ScratchpadColorTag.allCases) { tag in
                    tagFilterDot(tag, label: tag.displayName)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            if filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(DS.font(24))
                        .foregroundStyle(DS.textTertiary)
                    Text(store.notes.isEmpty ? "还没有便签" : "没有匹配的便签")
                        .font(DS.caption)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredNotes) { note in
                            noteListRow(note)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func tagFilterDot(_ tag: ScratchpadColorTag?, label: String) -> some View {
        let selected = filterTag == tag
        return Button {
            filterTag = tag
        } label: {
            if let tag {
                Circle()
                    .fill(tag.tint)
                    .frame(width: 12, height: 12)
                    .padding(3)
                    .overlay {
                        if selected {
                            Circle().strokeBorder(DS.text, lineWidth: 1.5)
                        }
                    }
            } else {
                Text(label)
                    .font(DS.font(11, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.text : DS.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(selected ? DS.selected : .clear, in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func noteListRow(_ note: ScratchpadNote) -> some View {
        let isSelected = note.id == selectedNoteID
        return Button {
            flushSave()
            selectNote(note)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(note.tag.tint)
                        .frame(width: 7, height: 7)
                    Text(note.displayTitle)
                        .font(DS.font(13.5, isSelected ? .semibold : .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(DS.font(10))
                            .foregroundStyle(DS.brand)
                    }
                }
                HStack {
                    Text(note.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(CN.time(note.updatedAt))
                        .font(DS.font(10.5).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? DS.selected : DS.card.opacity(0.6), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右侧编辑区

    @ViewBuilder
    private var rightEditorPane: some View {
        if let note = selectedNote {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("输入便签标题（留空自动取正文首行）", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(DS.font(17, .semibold))
                        .onChange(of: draftTitle) { scheduleSave() }

                    Spacer(minLength: 8)

                    HStack(spacing: 5) {
                        ForEach(ScratchpadColorTag.allCases) { tag in
                            Button {
                                draftTag = tag
                                scheduleSave()
                            } label: {
                                Circle()
                                    .fill(tag.tint)
                                    .frame(width: 12, height: 12)
                                    .padding(2)
                                    .overlay {
                                        if draftTag == tag {
                                            Circle().strokeBorder(DS.text, lineWidth: 1.5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(tag.displayName)
                        }
                    }

                    Button {
                        draftPinned.toggle()
                        store.togglePinned(id: note.id)
                    } label: {
                        Image(systemName: draftPinned ? "pin.fill" : "pin")
                            .foregroundStyle(draftPinned ? DS.brand : DS.textSecondary)
                    }
                    .buttonStyle(.dsGhost)
                    .help(draftPinned ? "取消置顶" : "置顶便签")

                    DSTabs(selection: $viewMode, options: [
                        (.edit, "编辑"),
                        (.preview, "预览"),
                    ])

                    Button {
                        deleteNote(id: note.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsGhost)
                    .help("删除此便签")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().overlay(DS.border)

                // 研发工具栏
                HStack(spacing: 8) {
                    Button("美化 JSON") {
                        applyJSONTransform(ScratchpadStore.formatJSON)
                    }
                    .buttonStyle(.dsSecondary)

                    Button("压缩 JSON") {
                        applyJSONTransform(ScratchpadStore.minifyJSON)
                    }
                    .buttonStyle(.dsSecondary)

                    Button("复制全文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draftContent, forType: .string)
                        feedback = (false, "已复制便签全文到剪贴板")
                    }
                    .buttonStyle(.dsSecondary)

                    Spacer(minLength: 4)

                    Button("转为待办") {
                        sendNoteToTodo(note)
                    }
                    .buttonStyle(.dsSecondary)

                    Button("记入日报草稿") {
                        sendNoteToDailyLog(note)
                    }
                    .buttonStyle(.dsSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(DS.sidebar.opacity(0.6))

                if let feedback {
                    DSBanner(feedback.isError ? .danger : .success, feedback.text)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                if viewMode == .edit {
                    TextEditor(text: $draftContent)
                        .font(DS.mono(13.5))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .padding(16)
                        .onChange(of: draftContent) {
                            scheduleSave()
                        }
                } else {
                    ScrollView {
                        DSMarkdownView(text: draftContent.isEmpty ? "_（暂无内容）_" : draftContent)
                            .padding(20)
                    }
                }

                Divider().overlay(DS.border)

                HStack(spacing: 12) {
                    let lineCount = draftContent.isEmpty ? 0 : draftContent.components(separatedBy: .newlines).count
                    Text("\(draftContent.count) 字符 · \(lineCount) 行")
                    Spacer()
                    Text("更新于 \(CN.dateTime(note.updatedAt))")
                }
                .font(DS.caption.monospacedDigit())
                .foregroundStyle(DS.textTertiary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(DS.font(30))
                    .foregroundStyle(DS.textTertiary)
                Text("随手记一段 JSON、curl 命令或会议笔记")
                    .font(DS.rowTitle)
                    .foregroundStyle(DS.textSecondary)
                HStack(spacing: 8) {
                    Button("新建便签") { createNewNote() }
                        .buttonStyle(.dsPrimary)
                    Button("从剪贴板新建") { createFromClipboard() }
                        .buttonStyle(.dsSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 动作

    private func selectNote(_ note: ScratchpadNote?) {
        selectedNoteID = note?.id
        draftTitle = note?.title ?? ""
        draftContent = note?.content ?? ""
        draftTag = note?.tag ?? .amber
        draftPinned = note?.isPinned ?? false
        feedback = nil
    }

    private func createNewNote() {
        flushSave()
        if let created = store.createNote() {
            selectNote(created)
            viewMode = .edit
        }
    }

    private func createFromClipboard() {
        flushSave()
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        if let created = store.createNote(content: clip) {
            selectNote(created)
            viewMode = .edit
            feedback = clip.isEmpty ? (false, "剪贴板为空，已创建空白便签") : (false, "已从剪贴板创建新便签")
        }
    }

    private func deleteNote(id: String) {
        saveTask?.cancel()
        store.delete(id: id)
        selectNote(store.notes.first)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        guard let id = selectedNoteID, var existing = store.notes.first(where: { $0.id == id }) else { return }
        guard existing.title != draftTitle || existing.content != draftContent || existing.tag != draftTag else { return }
        existing.title = draftTitle
        existing.content = draftContent
        existing.tag = draftTag
        store.update(existing)
    }

    private func applyJSONTransform(_ transform: (String) -> Result<String, Error>) {
        switch transform(draftContent) {
        case .success(let output):
            draftContent = output
            flushSave()
            feedback = (false, "JSON 处理完成")
        case .failure(let err):
            feedback = (true, "JSON 解析失败：\(err.localizedDescription)")
        }
    }

    private func sendNoteToTodo(_ note: ScratchpadNote) {
        flushSave()
        let title = ScratchpadStore.derivedTitle(title: draftTitle, content: draftContent)
        if context.todos.add(title: title, notes: draftContent, dueDate: WorkCalendar.dayString(Date())) != nil {
            feedback = (false, "已将「\(title)」加入今日待办")
        }
    }

    private func sendNoteToDailyLog(_ note: ScratchpadNote) {
        flushSave()
        let title = ScratchpadStore.derivedTitle(title: draftTitle, content: draftContent)
        let body = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let work = body.isEmpty ? "1. \(title)" : "1. \(title)：\(body.replacingOccurrences(of: "\n", with: " "))"
        if ZentaoLogPlugin.appendExternalDraft(work: work, hours: 1.0, on: Date(), database: context.database, settings: context.settings) {
            feedback = (false, "已将「\(title)」写入今日禅道日报草稿")
        } else {
            feedback = (true, "便签内容为空，无法写入日报草稿")
        }
    }

    // MARK: - 剪贴板历史视图

    private var filteredClipboardHistory: [ClipboardHistoryItem] {
        let q = clipQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return clipboardStore.historyItems.filter { item in
            if let clipKindFilter, item.contentKind != clipKindFilter { return false }
            if !q.isEmpty {
                return item.content.localizedCaseInsensitiveContains(q)
                    || item.sourceApp.localizedCaseInsensitiveContains(q)
            }
            return true
        }
    }

    private var selectedClipboardItem: ClipboardHistoryItem? {
        guard let selectedClipboardID else { return filteredClipboardHistory.first }
        return clipboardStore.historyItems.first { $0.id == selectedClipboardID } ?? filteredClipboardHistory.first
    }

    private var clipboardHistorySplitPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.textTertiary)
                    TextField("搜索剪贴板历史或来源应用", text: $clipQuery)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                    if !clipQuery.isEmpty {
                        Button { clipQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DS.font(12))
                                .foregroundStyle(DS.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: DS.s(30))
                .background(DS.card, in: .rect(cornerRadius: DS.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.controlRadius).strokeBorder(DS.borderStrong) }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        clipKindChip(nil, title: "全部")
                        ForEach(ClipboardContentKind.allCases) { kind in
                            clipKindChip(kind, title: kind.displayName)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                if filteredClipboardHistory.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.on.clipboard")
                            .font(DS.font(24))
                            .foregroundStyle(DS.textTertiary)
                        Text(clipboardStore.historyItems.isEmpty ? "复制文本/JSON/命令后将自动记录在这里" : "没有匹配的剪贴板记录")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filteredClipboardHistory) { item in
                                clipboardRow(item)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                    }
                }
            }
            .frame(width: DS.s(290))
            .background(DS.sidebar)

            Rectangle().fill(DS.border).frame(width: 1)

            clipboardDetailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.canvas)
        }
    }

    private func clipKindChip(_ kind: ClipboardContentKind?, title: String) -> some View {
        let selected = clipKindFilter == kind
        return Button {
            clipKindFilter = kind
        } label: {
            Text(title)
                .font(DS.font(11.5, selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.text : DS.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selected ? DS.selected : DS.card, in: .capsule)
                .overlay { Capsule().strokeBorder(selected ? DS.borderStrong : DS.border) }
        }
        .buttonStyle(.plain)
    }

    private func clipboardRow(_ item: ClipboardHistoryItem) -> some View {
        let isSelected = selectedClipboardItem?.id == item.id
        return Button {
            selectedClipboardID = item.id
            feedback = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.contentKind.systemImage)
                        .font(DS.font(11))
                        .foregroundStyle(DS.brand)
                    Text(item.displayTitle)
                        .font(DS.font(13, isSelected ? .semibold : .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if item.copyCount > 1 {
                        Text("×\(item.copyCount)")
                            .font(DS.font(10.5, .semibold).monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                HStack {
                    Text(item.sourceApp.isEmpty ? item.contentKind.displayName : "\(item.sourceApp) · \(item.charCount) 字")
                        .font(DS.font(11))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(CN.time(item.copiedAt))
                        .font(DS.font(10.5).monospacedDigit())
                        .foregroundStyle(DS.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? DS.selected : DS.card.opacity(0.6), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var clipboardDetailPane: some View {
        if let item = selectedClipboardItem {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(item.contentKind.displayName, systemImage: item.contentKind.systemImage)
                        .font(DS.sectionTitle)
                    if !item.sourceApp.isEmpty {
                        Text("来自 \(item.sourceApp)")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                    Spacer()

                    Button("复制") {
                        clipboardStore.copyToPasteboard(item.content)
                        feedback = (false, "已复制到剪贴板")
                    }
                    .buttonStyle(.dsPrimary)

                    Button("存为便签") {
                        if let note = store.createNote(content: item.content) {
                            selectNote(note)
                            activeTab = .notes
                            feedback = (false, "已转为便签笔记")
                        }
                    }
                    .buttonStyle(.dsSecondary)

                    Button("固定为片段") {
                        _ = clipboardStore.saveSnippet(title: item.displayTitle, content: item.content)
                        feedback = (false, "已固定到常用片段")
                    }
                    .buttonStyle(.dsSecondary)

                    Button {
                        clipboardStore.delete(id: item.id)
                        selectedClipboardID = clipboardStore.historyItems.first?.id
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsGhost)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().overlay(DS.border)

                if let feedback {
                    DSBanner(feedback.isError ? .danger : .success, feedback.text)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }

                ScrollView {
                    Text(item.content)
                        .font(DS.mono(13.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(DS.font(30))
                    .foregroundStyle(DS.textTertiary)
                Text("复制常用 JSON、cURL、SQL 或报错栈后将自动暂存")
                    .font(DS.rowTitle)
                    .foregroundStyle(DS.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 常用片段库视图

    private var selectedSnippetItem: ClipboardHistoryItem? {
        guard let selectedSnippetID else { return clipboardStore.snippetItems.first }
        return clipboardStore.snippetItems.first { $0.id == selectedSnippetID } ?? clipboardStore.snippetItems.first
    }

    private var snippetsSplitPane: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if clipboardStore.snippetItems.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "bookmark.slash")
                            .font(DS.font(24))
                            .foregroundStyle(DS.textTertiary)
                        Text("还没有常用片段")
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(clipboardStore.snippetItems) { item in
                                let isSelected = selectedSnippetItem?.id == item.id
                                Button {
                                    selectSnippet(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "bookmark.fill")
                                                .font(DS.font(10.5))
                                                .foregroundStyle(DS.brand)
                                            Text(item.displayTitle)
                                                .font(DS.font(13.5, isSelected ? .semibold : .medium))
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        Text(item.content.replacingOccurrences(of: "\n", with: " "))
                                            .font(DS.font(11.5))
                                            .foregroundStyle(DS.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(isSelected ? DS.selected : DS.card.opacity(0.6), in: .rect(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(isSelected ? DS.borderStrong : DS.border)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(width: DS.s(268))
            .background(DS.sidebar)

            Rectangle().fill(DS.border).frame(width: 1)

            snippetEditorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.canvas)
        }
    }

    @ViewBuilder
    private var snippetEditorPane: some View {
        if let item = selectedSnippetItem {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("片段名称（例如：线上数据库只读 SQL）", text: $snippetTitleDraft)
                        .textFieldStyle(.plain)
                        .font(DS.font(17, .semibold))

                    Spacer()

                    Button("复制片段") {
                        clipboardStore.copyToPasteboard(snippetContentDraft)
                        feedback = (false, "已复制片段内容到剪贴板")
                    }
                    .buttonStyle(.dsSecondary)

                    Button("保存修改") {
                        _ = clipboardStore.saveSnippet(id: item.id, title: snippetTitleDraft, content: snippetContentDraft)
                        feedback = (false, "已保存常用片段")
                    }
                    .buttonStyle(.dsPrimary)

                    Button {
                        clipboardStore.delete(id: item.id)
                        selectSnippet(clipboardStore.snippetItems.first)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsGhost)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().overlay(DS.border)

                if let feedback {
                    DSBanner(feedback.isError ? .danger : .success, feedback.text)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }

                TextEditor(text: $snippetContentDraft)
                    .font(DS.mono(13.5))
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(16)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bookmark")
                    .font(DS.font(30))
                    .foregroundStyle(DS.textTertiary)
                Text("保存高频 cURL、SQL、测试账号或常用命令")
                    .font(DS.rowTitle)
                    .foregroundStyle(DS.textSecondary)
                Button("新建常用片段") { createNewSnippet() }
                    .buttonStyle(.dsPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectSnippet(_ item: ClipboardHistoryItem?) {
        selectedSnippetID = item?.id
        snippetTitleDraft = item?.snippetTitle ?? ""
        snippetContentDraft = item?.content ?? ""
        feedback = nil
    }

    private func createNewSnippet() {
        if let created = clipboardStore.saveSnippet(title: "新建常用片段", content: "# 在此输入常用命令或模板\n") {
            selectSnippet(created)
        }
    }
}
