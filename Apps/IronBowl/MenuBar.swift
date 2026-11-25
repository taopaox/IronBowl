import IronBowlKit
import SwiftUI

/// 菜单栏上的图标 + 自定义信息。
struct MenuBarLabel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // 注意：这里不能用 TimelineView，会让状态栏按钮不停重绘。时间刷新靠 AppModel.now 的定时器。
        let text = app.menuBarText
        Text(text.isEmpty ? "🍚" : "🍚 \(text)")
            .onAppear {
                // 菜单栏标签启动时就会渲染，这里拿到 openWindow 给全局用。
                app.openMainWindow = { openWindow(id: "main") }
                app.openSettingsWindow = { openWindow(id: "settings") }
            }
    }
}

/// 点菜单栏图标弹出的面板。
struct MenuPanel: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            VStack(spacing: 2) {
                DSSidebarItem("今天", systemImage: "house", selected: false) { app.open(plugin: AppModel.homeID) }
                ForEach(app.enabledPlugins.filter { !$0.isComingSoon }, id: \.id) { plugin in
                    DSSidebarItem(plugin.title, systemImage: plugin.systemImage, selected: false) {
                        app.open(plugin: plugin.id)
                    }
                }
            }
            .padding(.horizontal, 6)

            let items = app.availableMenuBarItems.compactMap { item in item.text().map { (item.title, $0) } }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items, id: \.0) { title, value in
                        HStack {
                            Text(title).foregroundStyle(DS.textSecondary).lineLimit(1)
                            Spacer()
                            Text(value).monospacedDigit()
                        }
                        .font(DS.caption)
                    }
                }
                .padding(12)
                .background(DS.well, in: .rect(cornerRadius: 10))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            HStack(spacing: 4) {
                Button("设置") { app.openSettings() }.buttonStyle(.dsGhost)
                Spacer()
                Button("退出饭碗") { NSApp.terminate(nil) }.buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
            .padding(.top, 10)
        }
        .frame(width: DS.s(290))
        .background(DS.canvas)
        .id(app.fontScale)
    }

    private var header: some View {
        let _ = app.now
        let info = app.workCalendar.dayInfo(Date())
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("饭碗").font(DS.font(15, .semibold))
            Spacer()
            Text(Date().formatted(.dateTime.month().day().weekday(.wide)) + " · " + WorkCalendar.lunarString(Date()))
                .font(DS.caption).foregroundStyle(DS.textSecondary)
            if !info.isWorkday { Tag(info.name ?? "休", color: DS.danger) }
            if info.kind == .makeupWorkday { Tag("补班", color: DS.warning) }
        }
    }
}
