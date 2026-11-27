import IronBowlKit
import SwiftUI
import ZentaoLogPlugin

struct TodoMainView: View {
    let context: PluginContext
    @Environment(\.sidebarCollapsed) private var sidebarCollapsed

    enum FilterTab: String, CaseIterable, Hashable {
        case open = "未完成"
        case today = "今天"
        case scheduled = "有日期"
        case completed = "已完成"
        case all = "全部"
    }

    @State private var tab: FilterTab = .open
    @State private var query = ""
    @State private var newTitle = ""
    @State private var newNotes = ""
    @State private var hasDueDate = true
    @State private var newDueDate = Calendar.current.startOfDay(for: Date())
    @State private var hasReminder = false
    @State private var newRemindAt = Date().addingTimeInterval(3600)
    @State private var newPriority: TodoPriority = .normal
    @State private var newEstimatedHours: Double = 1.0
    @State private var showComposerDetails = false
    @State private var feedbackMessage: String?

    private var todos: TodoStore { context.todos }
    private var todayString: String { WorkCalendar.dayString(Date()) }

    private var filteredItems: [TodoItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return todos.items.filter { item in
            switch tab {
            case .open:
                if item.isCompleted { return false }
            case .today:
                if item.isCompleted { return false }
                guard let due = item.dueDate, !due.isEmpty else { return false }
                if due > todayString { return false }
            case .scheduled:
                if item.dueDate?.isEmpty ?? true { return false }
            case .completed:
                if !item.isCompleted { return false }
            case .all:
                break
            }
            if !q.isEmpty {
                let hitTitle = item.title.localizedCaseInsensitiveContains(q)
                let hitNotes = item.notes.localizedCaseInsensitiveContains(q)
                if !hitTitle && !hitNotes { return false }
            }
            return true
        }
    }

    private var overdueItems: [TodoItem] {
        filteredItems.filter { $0.isOverdue(todayString: todayString) }
    }

    private var todayItems: [TodoItem] {
        filteredItems.filter { !$0.isCompleted && $0.isDueToday(todayString: todayString) }
    }

    private var upcomingItems: [TodoItem] {
        filteredItems.filter { !$0.isCompleted && ($0.dueDate ?? "") > todayString }
    }

    private var unscheduledItems: [TodoItem] {
        filteredItems.filter { !$0.isCompleted && ($0.dueDate?.isEmpty ?? true) }
    }

    private var completedItems: [TodoItem] {
        filteredItems.filter(\.isCompleted)
    }

    var body: some View {
        VStack(spacing: 0) {
            DSPageHeader("待办与备忘", topPadding: 8) {
                DSTabs(
                    selection: $tab,
                    options: FilterTab.allCases.map { ($0, $0.rawValue) }
                )
                .padding(.leading, sidebarCollapsed ? 38 : 0)
            } actions: {
                let doneCount = todos.items.filter(\.isCompleted).count
                if doneCount > 0 {
                    Button("清理已完成 (\(doneCount))") {
                        todos.clearCompleted()
                    }
                    .buttonStyle(.dsSecondary)
                }
            }

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metricsRow
                    composerCard
                    searchBar

                    if let feedbackMessage {
                        DSBanner(.success, feedbackMessage)
                    }

                    if filteredItems.isEmpty {
                        emptyStateCard
                    } else {
                        if !overdueItems.isEmpty {
                            todoSection(title: "已逾期", tint: DS.danger, items: overdueItems)
                        }
                        if !todayItems.isEmpty {
                            todoSection(title: "今天", tint: DS.brand, items: todayItems)
                        }
                        if !upcomingItems.isEmpty {
                            todoSection(title: "后续日程", tint: DS.textSecondary, items: upcomingItems)
                        }
                        if !unscheduledItems.isEmpty {
                            todoSection(title: "随手待办（无日期）", tint: DS.textSecondary, items: unscheduledItems)
                        }
                        if !completedItems.isEmpty {
                            todoSection(title: "已完成", tint: DS.success, items: completedItems)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.canvas)
    }

    // MARK: - 统计指标

    private var metricsRow: some View {
        let todayCount = todos.todayIncompleteCount()
        let overdue = todos.overdueCount()
        let openCount = todos.items.filter { !$0.isCompleted }.count
        let doneToday = todos.items.filter {
            $0.isCompleted && ($0.completedAt.map { Calendar.current.isDateInToday($0) } ?? false)
        }.count

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
            DSMetric("今日待办", value: "\(todayCount) 项", detail: overdue > 0 ? "含 \(overdue) 项逾期" : "按计划推进", valueColor: todayCount > 0 ? DS.brand : DS.success)
            DSMetric("已逾期", value: "\(overdue) 项", detail: overdue > 0 ? "建议优先处理或改期" : "没有逾期事项", valueColor: overdue > 0 ? DS.danger : DS.text)
            DSMetric("进行中总计", value: "\(openCount) 项", detail: "与万年历实时共享")
            DSMetric("今日已完成", value: "\(doneToday) 项", detail: "可一键带入禅道日报", valueColor: doneToday > 0 ? DS.success : DS.text)
        }
    }

    // MARK: - 新建卡片

    private var composerCard: some View {
        DSCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("记一条待办或非代码工作（如：下午接口联调评审、周五发版）…", text: $newTitle)
                        .textFieldStyle(.ds)
                        .onSubmit { createTodo() }

                    Button(showComposerDetails ? "收起选项" : "日期 / 提醒") {
                        withAnimation(.snappy(duration: 0.2)) {
                            showComposerDetails.toggle()
                        }
                    }
                    .buttonStyle(.dsSecondary)

                    Button("添加") {
                        createTodo()
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if showComposerDetails {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("备注或补充说明（可选，带入日报时也会附上）", text: $newNotes)
                            .textFieldStyle(.ds)

                        HStack(spacing: 14) {
                            Toggle("设置日期", isOn: $hasDueDate)
                                .toggleStyle(.checkbox)
                            if hasDueDate {
                                DatePicker("", selection: $newDueDate, displayedComponents: .date)
                                    .labelsHidden()
                                Button("今天") {
                                    newDueDate = Calendar.current.startOfDay(for: Date())
                                }
                                .buttonStyle(.dsGhost)
                                Button("明天") {
                                    newDueDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
                                }
                                .buttonStyle(.dsGhost)
                            }

                            Spacer(minLength: 8)

                            Text("优先级")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                            DSPicker(
                                selection: $newPriority,
                                options: TodoPriority.allCases.map { DSPickerOption($0, title: $0.displayName) },
                                width: 96
                            )

                            Text("预估工时")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                            DSStepper(value: $newEstimatedHours, in: 0.5...12, step: 0.5) {
                                "\(WorkCalendar.hoursText($0))h"
                            }
                        }
                        .font(DS.body)

                        HStack(spacing: 12) {
                            Toggle("到点弹窗提醒", isOn: $hasReminder)
                                .toggleStyle(.checkbox)
                            if hasReminder {
                                DatePicker("", selection: $newRemindAt, displayedComponents: [.date, .hourAndMinute])
                                    .labelsHidden()
                            }
                            Spacer()
                        }
                        .font(DS.body)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DS.font(13))
                    .foregroundStyle(DS.textTertiary)
                TextField("搜索待办标题或备注", text: $query)
                    .textFieldStyle(.plain)
                    .font(DS.body)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
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
        }
    }

    private var emptyStateCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("暂无待办事项", systemImage: "checklist")
                    .font(DS.rowTitle)
                    .foregroundStyle(DS.text)
                Text("在上方输入框新增待办，或去「万年历」点击任意日期直接添加；完成后可一键带入「禅道日报」草稿。")
                    .font(DS.body)
                    .foregroundStyle(DS.textSecondary)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func todoSection(title: String, tint: Color, items: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(DS.sectionTitle)
                    .foregroundStyle(tint)
                Text("(\(items.count))")
                    .font(DS.caption.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
            }
            .padding(.leading, 2)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    TodoItemRow(
                        item: item,
                        todayString: todayString,
                        onToggle: {
                            todos.toggleCompleted(id: item.id)
                        },
                        onCyclePriority: {
                            var updated = item
                            let all = TodoPriority.allCases
                            let idx = all.firstIndex(of: item.priorityLevel) ?? 0
                            updated.priorityLevel = all[(idx + 1) % all.count]
                            todos.update(updated)
                        },
                        onSendToDailyLog: {
                            if TodoPlugin.sendToDailyDraft(item: item, context: context) {
                                feedbackMessage = "已将「\(item.title)」带入禅道日报草稿"
                            }
                        },
                        onOpenCalendar: {
                            context.openPlugin("calendar")
                        },
                        onDelete: {
                            todos.delete(id: item.id)
                        }
                    )
                }
            }
        }
    }

    private func createTodo() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let dueString = hasDueDate ? WorkCalendar.dayString(newDueDate) : nil
        let remindDate = hasReminder ? newRemindAt : nil
        if todos.add(
            title: trimmed,
            notes: newNotes,
            dueDate: dueString,
            remindAt: remindDate,
            priority: newPriority,
            estimatedHours: newEstimatedHours
        ) != nil {
            newTitle = ""
            newNotes = ""
            hasReminder = false
        }
    }
}

private struct TodoItemRow: View {
    let item: TodoItem
    let todayString: String
    let onToggle: () -> Void
    let onCyclePriority: () -> Void
    let onSendToDailyLog: () -> Void
    let onOpenCalendar: () -> Void
    let onDelete: () -> Void

    var body: some View {
        DSCard(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onToggle) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(DS.font(17))
                        .foregroundStyle(item.isCompleted ? DS.success : DS.textTertiary)
                        .padding(.top, 1)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(DS.rowTitle)
                            .strikethrough(item.isCompleted)
                            .foregroundStyle(item.isCompleted ? DS.textTertiary : DS.text)

                        if item.priorityLevel != .normal && !item.isCompleted {
                            Button(action: onCyclePriority) {
                                Tag(item.priorityLevel.displayName, color: item.priorityLevel.tint)
                            }
                            .buttonStyle(.plain)
                            .help("点击切换优先级")
                        }

                        if let type = item.zentaoObjectType, let zid = item.zentaoObjectID {
                            Tag("禅道\(type == "bug" ? "Bug" : "任务") #\(zid)", color: DS.brand)
                        }

                        if let logged = item.loggedDate {
                            Tag("已入 \(logged) 日报", color: DS.success)
                        }
                    }

                    if !item.notes.isEmpty {
                        Text(item.notes)
                            .font(DS.caption)
                            .foregroundStyle(DS.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        if let due = item.dueDate, !due.isEmpty {
                            let isOverdue = item.isOverdue(todayString: todayString)
                            Label(due == todayString ? "今天" : due, systemImage: "calendar")
                                .font(DS.caption)
                                .foregroundStyle(isOverdue ? DS.danger : DS.textSecondary)
                        }

                        if let remind = item.remindAt, !item.isCompleted {
                            Label(CN.dateTime(remind), systemImage: item.remindedAt == nil ? "bell" : "bell.slash")
                                .font(DS.caption)
                                .foregroundStyle(item.remindedAt == nil ? DS.warning : DS.textTertiary)
                        }

                        Label("\(WorkCalendar.hoursText(item.estimatedHours))h", systemImage: "clock")
                            .font(DS.caption.monospacedDigit())
                            .foregroundStyle(DS.textTertiary)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    if item.loggedDate == nil {
                        Button("记入日报", action: onSendToDailyLog)
                            .buttonStyle(.dsSecondary)
                            .help("把这条工作内容和预估工时加入到禅道日报草稿")
                    }

                    if item.dueDate != nil {
                        Button(action: onOpenCalendar) {
                            Image(systemName: "calendar")
                        }
                        .buttonStyle(.dsGhost)
                        .help("在万年历中查看")
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(DS.danger)
                    }
                    .buttonStyle(.dsGhost)
                    .help("删除待办")
                }
            }
        }
    }
}
