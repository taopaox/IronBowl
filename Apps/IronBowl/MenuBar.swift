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
        }
    }
}

/// 点菜单栏图标弹出的玻璃面板。
struct MenuPanel: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 6) {
                    ForEach(app.enabledPlugins.filter { !$0.isComingSoon }, id: \.id) { plugin in
                        Button {
                            app.open(plugin: plugin.id)
                        } label: {
                            Label(plugin.title, systemImage: plugin.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                    }
                }
            }
            let items = app.availableMenuBarItems.compactMap { item in item.text().map { (item.title, $0) } }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.0) { title, value in
                        HStack {
                            Text(title).foregroundStyle(.secondary)
                            Spacer()
                            Text(value).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 4)
            }
            Divider()
            HStack {
                Button("打开饭碗") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("设置…") {
                    openSettings()
                    NSApp.activate()
                }
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        let info = app.workCalendar.dayInfo(Date())
        return HStack(alignment: .firstTextBaseline) {
            Text("🍚 饭碗").font(.headline)
            Spacer()
            Text(Date().formatted(.dateTime.month().day().weekday(.wide)))
                .font(.caption).foregroundStyle(.secondary)
            if !info.isWorkday { Tag(info.name ?? "休", color: .red) }
            if info.kind == .makeupWorkday { Tag("补班", color: .orange) }
        }
    }
}
