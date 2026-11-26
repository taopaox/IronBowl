import IronBowlKit
import SwiftUI

/// 菜单栏上的双行微缩仪表卡。
struct MenuBarLabel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 注意：这里不能用 TimelineView，会让状态栏按钮不停重绘。时间刷新靠 AppModel.now 的定时器。
        Image(nsImage: MenuBarCardRenderer.renderImage(segments: app.menuBarCardSegments))
            .onAppear {
                // 菜单栏标签启动时就会渲染，这里拿到 openWindow 给全局用，并确保 NSApp 就绪后应用外观和 Dock 策略。
                app.openMainWindow = { openWindow(id: "main") }
                app.openSettingsWindow = { openWindow(id: "settings") }
                app.applyDockMode()
                app.applyAppearance()
            }
    }
}

/// 点菜单栏图标弹出的卡片式快捷面板。
struct MenuPanel: View {
    let app: AppModel
    @Environment(\.dismissMenuBarPopover) private var dismissMenuBarPopover

    private func runAndDismiss(_ action: () -> Void) {
        dismissMenuBarPopover()
        action()
    }

    var body: some View {
        let _ = app.now
        let now = Date()
        let cards = orderedStatusCards()
        let shortcuts = shortcutEntries()

        VStack(alignment: .leading, spacing: 12) {
            header(now: now)

            DSSloganView(style: .banner)
                .padding(.horizontal, 2)

            MenuWorkHeroCard(app: app, now: now) {
                runAndDismiss { app.open(plugin: AppModel.homeID) }
            }

            if !cards.isEmpty {
                statusCardGrid(cards)
            }

            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快捷入口")
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, 2)

                    let columnCount = shortcutColumnCount(for: shortcuts.count)
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount),
                        spacing: 8
                    ) {
                        ForEach(shortcuts) { entry in
                            MenuShortcutTile(entry: entry) {
                                runAndDismiss { app.open(plugin: entry.id) }
                            }
                        }
                    }
                }
            }

            footer
        }
        .padding(14)
        .frame(width: DS.s(360))
        .background(DS.groupBackground)
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }

    // MARK: - 顶部品牌与日期栏

    private func header(now: Date) -> some View {
        let info = app.workCalendar.dayInfo(now)
        return HStack(alignment: .center, spacing: 10) {
            Text("🍚")
                .font(DS.font(16))
                .frame(width: DS.s(30), height: DS.s(30))
                .background(DS.card, in: .rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.border) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text("饭碗").font(DS.font(14.5, .semibold))
                    Text(Bundle.main.displayVersion)
                        .font(DS.font(10.5, .medium))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(DS.card, in: .capsule)
                        .overlay { Capsule().strokeBorder(DS.border) }
                        .help("当前版本 \(Bundle.main.fullVersion)")
                }

                HStack(spacing: 5) {
                    Text(CN.monthDay(now) + " " + CN.weekday(now) + " · " + WorkCalendar.lunarString(now))
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                    if !info.isWorkday { Tag(info.name ?? "休", color: DS.danger) }
                    if info.kind == .makeupWorkday { Tag("补班", color: DS.warning) }
                }
            }

            Spacer(minLength: 4)

            MenuHeaderWorkspaceButton {
                runAndDismiss { app.open(plugin: AppModel.homeID) }
            }
        }
    }

    // MARK: - 今日概览状态卡片网格

    @ViewBuilder
    private func statusCardGrid(_ cards: [HomeCard]) -> some View {
        if cards.count == 1, let card = cards.first {
            MenuStatusCard(card: card) {
                runAndDismiss { (card.action ?? { app.open(plugin: AppModel.homeID) })() }
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(cards) { card in
                    MenuStatusCard(card: card) {
                        runAndDismiss { (card.action ?? { app.open(plugin: AppModel.homeID) })() }
                    }
                }
            }
        }
    }

    private func orderedStatusCards() -> [HomeCard] {
        let all = app.enabledPlugins.flatMap(\.homeCards)
        let priority = ["zentao.today", "calendar.weather", "scheduler.next", "report.weekly"]
        var picked: [HomeCard] = []
        var seen = Set<String>()
        for id in priority {
            if let match = all.first(where: { $0.id == id }), seen.insert(match.id).inserted {
                picked.append(match)
            }
        }
        for card in all where picked.count < 4 {
            if seen.insert(card.id).inserted {
                picked.append(card)
            }
        }
        return picked
    }

    // MARK: - 快捷入口数据

    private func shortcutEntries() -> [ShortcutEntry] {
        var entries = [
            ShortcutEntry(
                id: AppModel.homeID,
                title: "今天",
                systemImage: "house",
                tint: DS.brand,
                badge: nil
            ),
        ]
        for plugin in app.enabledPlugins where !plugin.isComingSoon {
            entries.append(
                ShortcutEntry(
                    id: plugin.id,
                    title: plugin.sidebarTitle,
                    systemImage: plugin.systemImage,
                    tint: Self.shortcutTint(for: plugin.id),
                    badge: plugin.sidebarBadge
                )
            )
        }
        return entries
    }

    private func shortcutColumnCount(for count: Int) -> Int {
        if count <= 3 { return max(1, count) }
        if count == 4 { return 4 }
        if count <= 6 { return 3 }
        return 4
    }

    private static func shortcutTint(for pluginID: String) -> Color {
        switch pluginID {
        case "zentao.log": DS.brand
        case "report.weekly", "report.monthly": DS.toggle
        case "calendar": .blue
        case "feishu": .indigo
        case "ai.web": .purple
        case "scheduler": .orange
        default: DS.textSecondary
        }
    }

    // MARK: - 底部操作栏

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                runAndDismiss { app.openSettings() }
            } label: {
                Label("设置", systemImage: "gearshape")
                    .font(DS.font(12.5))
            }
            .buttonStyle(.dsGhost)

            Spacer()

            Button {
                runAndDismiss { NSApp.terminate(nil) }
            } label: {
                Label("退出饭碗", systemImage: "power")
                    .font(DS.font(12.5))
            }
            .buttonStyle(.dsGhost)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }
}

// MARK: - 顶部工作台按钮

private struct MenuHeaderWorkspaceButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("工作台")
                    .font(DS.font(12, .medium))
                Image(systemName: "arrow.up.right")
                    .font(DS.font(10.5, .semibold))
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 9)
            .frame(height: DS.s(26))
            .background(hovering ? DS.hover : DS.card, in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(hovering ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("打开主工作台")
    }
}

// MARK: - 今日上下班主卡

private struct MenuWorkHeroCard: View {
    let app: AppModel
    let now: Date
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let cal = app.workCalendar
        let info = cal.dayInfo(now)
        let ot = cal.overtimeHours(on: now)
        let end = cal.effectiveWorkEnd(on: now)
        let hasClockIn = cal.clockIn(on: now) != nil

        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: info.isWorkday ? "briefcase.fill" : "cup.and.saucer.fill")
                        .font(DS.font(11.5))
                        .foregroundStyle(info.isWorkday ? (ot > 0 ? .purple : DS.brand) : DS.toggle)
                    Text(info.isWorkday ? "今天上班" : (info.name ?? "今天休息"))
                        .font(DS.font(12, .medium))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if ot > 0 {
                        Tag("加班 +\(WorkCalendar.hoursText(ot))h", color: .purple)
                    } else if info.isWorkday && hasClockIn {
                        Tag("已打卡", color: DS.success)
                    }
                }

                if info.isWorkday {
                    workdayHeroContent(cal: cal, end: end, ot: ot)
                    workdayTimeFooter(cal: cal, ot: ot)
                } else {
                    offDayHeroContent(cal: cal, ot: ot)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.card, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(hovering ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(info.isWorkday ? cal.scheduleText(on: now) : (info.name ?? "今天休息"))
    }

    @ViewBuilder
    private func workdayHeroContent(cal: WorkCalendar, end: Date?, ot: Double) -> some View {
        if let end, end > now {
            let progress = cal.workProgress(on: now) ?? 0
            let accent: Color = ot > 0 ? .purple : DS.brand
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("距下班 \(remainingTimeText(to: end, from: now))")
                        .font(DS.font(18.5, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(DS.font(13, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                progressBar(progress: progress, tint: accent)
            }
        } else {
            let accent: Color = ot > 0 ? .purple : DS.success
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                        .font(DS.font(15))
                        .foregroundStyle(DS.brand)
                    Text("已下班，辛苦了")
                        .font(DS.font(18.5, .semibold))
                        .foregroundStyle(DS.text)
                    Spacer(minLength: 4)
                    Text("100%")
                        .font(DS.font(12, .medium))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                progressBar(progress: 1, tint: accent)
            }
        }
    }

    private func workdayTimeFooter(cal: WorkCalendar, ot: Double) -> some View {
        HStack(spacing: 6) {
            Label("上班 \(cal.onWorkTimeText(on: now))", systemImage: "sunrise")
                .font(DS.font(11.5).monospacedDigit())
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let endText = cal.offWorkTimeText(on: now) {
                Label("下班 \(endText)", systemImage: "sunset")
                    .font(DS.font(11.5).monospacedDigit())
                    .foregroundStyle(ot > 0 ? .purple : DS.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
    }

    @ViewBuilder
    private func offDayHeroContent(cal: WorkCalendar, ot: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ot > 0 ? "辛苦加班" : "好好休息")
                .font(DS.font(18.5, .semibold))
                .foregroundStyle(DS.text)
            if let next = cal.nextHoliday(after: now) {
                let days = Calendar.current.dateComponents(
                    [.day],
                    from: Calendar.current.startOfDay(for: now),
                    to: next.date
                ).day ?? 0
                Text("距\(next.name) \(days) 天")
                    .font(DS.font(12))
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }

    private func progressBar(progress: Double, tint: Color) -> some View {
        let clamped = min(1, max(0, progress))
        return GeometryReader { geo in
            let width = clamped > 0 ? max(4, geo.size.width * clamped) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(DS.well)
                if width > 0 {
                    Capsule().fill(tint).frame(width: width)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - 今日概览状态卡片

private struct MenuStatusCard: View {
    let card: HomeCard
    let action: () -> Void
    @State private var hovering = false

    private static let cardAppearance: [String: (icon: String, tint: Color)] = [
        "zentao.today": ("square.and.pencil", DS.brand),
        "calendar.weather": ("cloud.sun.fill", .cyan),
        "scheduler.next": ("clock.badge.checkmark", .indigo),
        "report.weekly": ("doc.text", DS.toggle),
        "report.monthly": ("doc.richtext", DS.toggle),
        "feishu.card": ("book.pages", .blue),
        "aiweb.card": ("sparkles", .purple),
    ]

    var body: some View {
        let meta = Self.cardAppearance[card.id] ?? ("square.grid.2x2", DS.textSecondary)
        let value = card.value()
        let detail = card.detail()

        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: meta.icon)
                        .font(DS.font(10.5, .semibold))
                        .foregroundStyle(meta.tint)
                        .frame(width: DS.s(20), height: DS.s(20))
                        .background(meta.tint.opacity(0.14), in: .rect(cornerRadius: 6))

                    Text(card.label)
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    Image(systemName: "chevron.right")
                        .font(DS.font(9.5, .semibold))
                        .foregroundStyle(DS.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }

                Text(value)
                    .font(DS.font(16, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor(for: value))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.font(11))
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.card, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func valueColor(for value: String) -> Color {
        switch value {
        case "未写", "未生成", "未设置": DS.warning
        case "已提交", "已生成": DS.success
        default: value.hasPrefix("已写") ? DS.success : DS.text
        }
    }
}

// MARK: - 快捷入口瓷砖卡

private struct ShortcutEntry: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let badge: SidebarBadge?
}

private struct MenuShortcutTile: View {
    let entry: ShortcutEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    Image(systemName: entry.systemImage)
                        .font(DS.font(13, .medium))
                        .foregroundStyle(entry.tint)
                        .frame(width: DS.s(28), height: DS.s(28))
                        .background(entry.tint.opacity(0.13), in: .rect(cornerRadius: 8))

                    Text(entry.title)
                        .font(DS.font(11.5, .medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)

                if let badge = entry.badge {
                    Circle()
                        .fill(badge.color)
                        .frame(width: 6, height: 6)
                        .padding(6)
                }
            }
            .background(hovering ? DS.hover : DS.card, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? DS.borderStrong : DS.border)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.badge.map { "\(entry.title) · \($0.text)" } ?? entry.title)
    }
}
