import IronBowlKit
import SwiftUI

struct TaskEditorSheet: View {
    let scheduler: TaskScheduler
    let existingTask: ScheduledTask?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var actionID: String
    @State private var isEnabled: Bool
    @State private var scheduleKind: TaskScheduleKind
    @State private var timeDate: Date
    @State private var weekdays: [Int]
    @State private var intervalMinutes: Int
    @State private var misfirePolicy: MisfirePolicy
    @State private var notifyPolicy: TaskNotifyPolicy
    @State private var notifyStyle: ReminderStyle
    @State private var parameters: [String: String]

    private let weekdayOptions = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]

    init(scheduler: TaskScheduler, existingTask: ScheduledTask?) {
        self.scheduler = scheduler
        self.existingTask = existingTask

        let actions = scheduler.registeredActions
        let initialActionID = existingTask?.actionID ?? actions.first?.id ?? TaskScheduler.coreReminderActionID
        let initialAction = scheduler.action(id: initialActionID) ?? actions.first
        let initialSchedule = existingTask?.schedule ?? TaskSchedule(kind: .workdays, hour: 17, minute: 0)
        let initialTime = Calendar.current.date(
            bySettingHour: initialSchedule.hour,
            minute: initialSchedule.minute,
            second: 0,
            of: Date()
        ) ?? Date()

        var mergedParams = initialAction?.defaultParameters ?? [:]
        if let existingParams = existingTask?.parameters {
            for (k, v) in existingParams {
                mergedParams[k] = v
            }
        }

        _name = State(initialValue: existingTask?.name ?? initialAction?.defaultName ?? "定时任务")
        _actionID = State(initialValue: initialActionID)
        _isEnabled = State(initialValue: existingTask?.isEnabled ?? true)
        _scheduleKind = State(initialValue: initialSchedule.kind)
        _timeDate = State(initialValue: initialTime)
        _weekdays = State(initialValue: initialSchedule.weekdays)
        _intervalMinutes = State(initialValue: initialSchedule.intervalMinutes)
        _misfirePolicy = State(initialValue: existingTask?.misfirePolicy ?? .runIfMissedToday)
        _notifyPolicy = State(initialValue: existingTask?.notifyPolicy ?? .onSuccessAndFailure)
        _notifyStyle = State(initialValue: existingTask?.notifyStyle ?? .cornerCard)
        _parameters = State(initialValue: mergedParams)
    }

    private var selectedAction: ScheduledTaskAction? {
        scheduler.action(id: actionID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingTask == nil ? "新建定时任务" : "编辑定时任务")
                    .font(DS.pageTitle)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(DS.canvas)

            Divider().overlay(DS.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basicSection
                    scheduleSection
                    if let specs = selectedAction?.parameterSpecs, !specs.isEmpty {
                        parametersSection(specs)
                    }
                    notifySection
                }
                .padding(22)
            }
            .background(DS.groupBackground)

            Divider().overlay(DS.border)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.dsSecondary)
                Button("保存") { save() }
                    .buttonStyle(.dsPrimary)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(DS.canvas)
        }
        .frame(width: DS.s(640), height: DS.s(620))
    }

    private var basicSection: some View {
        let actionOptions = buildActionOptions()
        return DSSection("基本信息") {
            DSRow("任务名称") {
                TextField("", text: $name, prompt: Text("输入定时任务名称"))
                    .textFieldStyle(.ds)
                    .frame(width: 280)
            }
            DSRow("执行动作", description: selectedAction?.subtitle) {
                DSPicker(
                    selection: Binding(
                        get: { actionID },
                        set: { switchAction(to: $0) }
                    ),
                    options: actionOptions,
                    width: 280
                )
            }
            DSRow("启用任务", description: "关闭后不会按计划自动触发，仍可手动点击立即运行。") {
                DSToggle(isOn: $isEnabled)
            }
        }
    }

    private var scheduleSection: some View {
        DSSection("触发时间") {
            DSRow("执行周期") {
                DSPicker(
                    selection: $scheduleKind,
                    options: TaskScheduleKind.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    },
                    width: 220
                )
            }
            if scheduleKind == .interval {
                DSRow("执行间隔", description: "按固定分钟数循环执行。") {
                    DSStepper(intValue: $intervalMinutes, in: 5...1440, step: 5) { minutes in
                        minutes >= 60 && minutes % 60 == 0
                            ? "\(minutes / 60) 小时"
                            : "\(minutes) 分钟"
                    }
                }
            } else {
                DSRow("触发时刻") {
                    DatePicker("", selection: $timeDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                if scheduleKind == .weekly {
                    DSRow("重复星期", description: "至少选择一天。") {
                        HStack(spacing: 4) {
                            ForEach(weekdayOptions, id: \.0) { day, title in
                                let on = weekdays.contains(day)
                                Button(title) {
                                    var list = weekdays
                                    if on {
                                        if list.count > 1 {
                                            list.removeAll { $0 == day }
                                        }
                                    } else {
                                        list.append(day)
                                    }
                                    weekdays = list.sorted()
                                }
                                .buttonStyle(.plain)
                                .font(DS.font(13, on ? .semibold : .regular))
                                .foregroundStyle(on ? DS.onPrimary : DS.textSecondary)
                                .frame(width: 28, height: 28)
                                .background(on ? DS.primaryFill : DS.well, in: .circle)
                            }
                        }
                    }
                }
                DSRow("错过触发时") {
                    DSPicker(
                        selection: $misfirePolicy,
                        options: MisfirePolicy.allCases.map {
                            DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                        },
                        width: 240
                    )
                }
            }
        }
    }

    private func parametersSection(_ specs: [ScheduledActionParameterSpec]) -> some View {
        DSSection("动作参数") {
            ForEach(specs) { spec in
                parameterRow(spec)
            }
        }
    }

    @ViewBuilder
    private func parameterRow(_ spec: ScheduledActionParameterSpec) -> some View {
        switch spec.kind {
        case .bool:
            DSRow(spec.title, description: spec.description) {
                DSToggle(isOn: Binding(
                    get: {
                        let raw = (parameters[spec.key] ?? spec.defaultValue).lowercased()
                        return raw == "true" || raw == "1" || raw == "yes"
                    },
                    set: { parameters[spec.key] = $0 ? "true" : "false" }
                ))
            }
        case .text(let placeholder):
            DSRow(spec.title, description: spec.description) {
                TextField(
                    "",
                    text: Binding(
                        get: { parameters[spec.key] ?? spec.defaultValue },
                        set: { parameters[spec.key] = $0 }
                    ),
                    prompt: Text(placeholder)
                )
                .textFieldStyle(.ds)
                .frame(width: 280)
            }
        case .multiline(let placeholder):
            DSBlockRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.title).font(DS.rowTitle)
                    if let desc = spec.description {
                        Text(desc).font(DS.caption).foregroundStyle(DS.textSecondary)
                    }
                    ZStack(alignment: .topLeading) {
                        let text = parameters[spec.key] ?? spec.defaultValue
                        if text.isEmpty {
                            Text(placeholder)
                                .font(DS.body)
                                .foregroundStyle(DS.textTertiary)
                                .padding(.top, 2)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: Binding(
                            get: { parameters[spec.key] ?? spec.defaultValue },
                            set: { parameters[spec.key] = $0 }
                        ))
                        .font(DS.mono(13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 74, maxHeight: 140)
                    }
                    .padding(8)
                    .background(DS.well, in: .rect(cornerRadius: DS.controlRadius))
                }
            }
        case .int(let minVal, let maxVal, let step, let unit):
            DSRow(spec.title, description: spec.description) {
                DSStepper(
                    intValue: Binding(
                        get: { Int(parameters[spec.key] ?? spec.defaultValue) ?? Int(spec.defaultValue) ?? minVal },
                        set: { parameters[spec.key] = String($0) }
                    ),
                    in: minVal...maxVal,
                    step: step
                ) { "\($0) \(unit)" }
            }
        case .choice(let choices):
            DSRow(spec.title, description: spec.description) {
                DSPicker(
                    selection: Binding(
                        get: { parameters[spec.key] ?? spec.defaultValue },
                        set: { parameters[spec.key] = $0 }
                    ),
                    options: choices.map {
                        DSPickerOption($0.value, title: $0.title, subtitle: $0.subtitle)
                    },
                    width: 260
                )
            }
        }
    }

    private var notifySection: some View {
        DSSection("执行通知") {
            DSRow("通知时机") {
                DSPicker(
                    selection: $notifyPolicy,
                    options: TaskNotifyPolicy.allCases.map {
                        DSPickerOption($0, title: $0.displayName, subtitle: $0.detail)
                    },
                    width: 240
                )
            }
            if notifyPolicy != .never {
                DSRow("提醒方式") {
                    DSPicker(
                        selection: $notifyStyle,
                        options: ReminderStyle.allCases.map {
                            DSPickerOption($0, title: styleShortName($0), subtitle: $0.displayName)
                        },
                        width: 240
                    )
                }
            }
        }
    }

    private func buildActionOptions() -> [DSPickerOption<String>] {
        var options = scheduler.registeredActions.map {
            DSPickerOption($0.id, title: $0.title, subtitle: $0.subtitle)
        }
        if !options.contains(where: { $0.value == actionID }) {
            options.insert(
                DSPickerOption(actionID, title: "\(actionID)（对应插件未启用）", subtitle: "请先在通用设置中启用对应插件。"),
                at: 0
            )
        }
        return options
    }

    private func switchAction(to newActionID: String) {
        let oldDefaultName = selectedAction?.defaultName
        actionID = newActionID
        guard let nextAction = scheduler.action(id: newActionID) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == oldDefaultName {
            name = nextAction.defaultName
        }
        parameters = nextAction.defaultParameters
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: timeDate)
        let schedule = TaskSchedule(
            kind: scheduleKind,
            hour: comps.hour ?? 17,
            minute: comps.minute ?? 0,
            weekdays: weekdays,
            intervalMinutes: intervalMinutes
        )
        let task = ScheduledTask(
            id: existingTask?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            actionID: actionID,
            isEnabled: isEnabled,
            schedule: schedule,
            misfirePolicy: misfirePolicy,
            notifyPolicy: notifyPolicy,
            notifyStyle: notifyStyle,
            parameters: parameters,
            nextRunAt: existingTask?.nextRunAt,
            lastRunAt: existingTask?.lastRunAt,
            lastFiredSlot: existingTask?.lastFiredSlot,
            lastStatus: existingTask?.lastStatus,
            lastSummary: existingTask?.lastSummary,
            createdAt: existingTask?.createdAt ?? Date(),
            updatedAt: Date()
        )
        scheduler.saveTask(task)
        dismiss()
    }

    private func styleShortName(_ style: ReminderStyle) -> String {
        switch style {
        case .system: "系统通知"
        case .cornerCard: "右上角卡片"
        case .centerDialog: "中央弹框"
        }
    }
}
