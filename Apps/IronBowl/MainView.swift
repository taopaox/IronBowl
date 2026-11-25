import IronBowlKit
import SwiftUI

/// 主窗口：左边浅灰侧栏，右边白色内容区（WorkBuddy 风格）。
struct MainView: View {
    @Bindable var app: AppModel
    @AppStorage("sidebarCollapsed") private var collapsed = false

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                Sidebar(app: app, collapsed: $collapsed)
                    .frame(width: DS.s(216))
                    .transition(.move(edge: .leading))
                Rectangle().fill(DS.border).frame(width: 1)
            }
            ZStack(alignment: .topLeading) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.canvas)
                if collapsed {
                    Button { withAnimation(.snappy) { collapsed = false } } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.dsGhost)
                        .help("展开侧边栏")
                        .padding(.leading, 82)
                        .padding(.top, 10)
                }
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 600)
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
        .onAppear { app.mainWindow(isOpen: true) }
        .onDisappear { app.mainWindow(isOpen: false) }
    }

    @ViewBuilder
    private var detail: some View {
        if app.selection == AppModel.homeID {
            HomeView(app: app)
        } else if let plugin = app.plugin(app.selection), app.enabledIDs.contains(plugin.id) {
            plugin.makeMainView().id(plugin.id)
        } else {
            HomeView(app: app)
        }
    }
}

struct Sidebar: View {
    let app: AppModel
    @Binding var collapsed: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部：给红绿灯留位置，右边是收起按钮
            HStack {
                Spacer()
                Button { withAnimation(.snappy) { collapsed = true } } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.dsGhost)
                    .help("收起侧边栏")
            }
            .frame(height: 40)
            .padding(.horizontal, 10)

            HStack(spacing: 6) {
                Text("饭碗").font(DS.font(16, .semibold))
                Text(Bundle.main.shortVersion).font(DS.font(12)).foregroundStyle(DS.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    DSSidebarItem("今天", systemImage: "house", selected: app.selection == AppModel.homeID) {
                        app.select(AppModel.homeID)
                    }
                    ForEach(app.enabledPlugins, id: \.id) { plugin in
                        DSSidebarItem(plugin.title, systemImage: plugin.systemImage,
                                      selected: app.selection == plugin.id,
                                      badge: plugin.isComingSoon ? "即将推出" : nil) {
                            app.select(plugin.id)
                        }
                    }

                    let recents = app.enabledPlugins.flatMap(\.sidebarRecents)
                    if !recents.isEmpty {
                        DSSidebarSection("最近日志")
                        ForEach(recents) { item in
                            RecentRow(item: item)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            TodayCard(app: app).padding(.horizontal, 10).padding(.bottom, 8)

            HStack(spacing: 2) {
                Text("🍚").font(DS.font(16))
                Text(NSFullUserName().isEmpty ? "我" : NSFullUserName()).font(DS.font(13.5))
                    .lineLimit(1)
                Spacer()
                Button { openWindow(id: "settings") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.dsGhost)
                    .help("设置")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
        }
        .background(DS.sidebar)
    }
}

private struct RecentRow: View {
    let item: SidebarRecent
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            HStack {
                Text(item.title).font(DS.font(13.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text(item.trailing).font(DS.font(12)).foregroundStyle(DS.textTertiary)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(hovering ? DS.hover : .clear, in: .rect(cornerRadius: DS.controlRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 侧栏底部的小卡：今日工时 + 下班倒计时。
private struct TodayCard: View {
    let app: AppModel

    var body: some View {
        let _ = app.now
        let info = app.workCalendar.dayInfo(Date())
        VStack(alignment: .leading, spacing: 4) {
            Text(info.isWorkday ? "今天上班" : (info.name ?? "今天休息"))
                .font(DS.font(12.5)).foregroundStyle(DS.textSecondary)
            if info.isWorkday, let end = app.workCalendar.workEnd(), end > Date() {
                Text("距下班 \(countdown(to: end))").font(DS.font(15, .semibold)).monospacedDigit()
                ProgressView(value: workProgress(end: end))
                    .progressViewStyle(.linear)
                    .tint(DS.brand)
            } else {
                Text(info.isWorkday ? "已下班，辛苦了" : "好好休息").font(DS.font(15, .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.border) }
    }

    func workProgress(end: Date) -> Double {
        let start = end.addingTimeInterval(-(app.workCalendar.defaultWorkHours * 3600 + Double(app.settings[WorkCalendar.lunchMinutesKey]) * 60))
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }
}

extension Bundle {
    var shortVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
