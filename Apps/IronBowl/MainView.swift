import IronBowlKit
import SwiftUI

struct MainView: View {
    @Bindable var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("饭碗") {
                    ForEach(app.enabledPlugins, id: \.id) { plugin in
                        Label {
                            HStack {
                                Text(plugin.title)
                                if plugin.isComingSoon {
                                    Spacer()
                                    Text("即将推出").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        } icon: {
                            Image(systemName: plugin.systemImage)
                        }
                        .tag(plugin.id)
                        .foregroundStyle(plugin.isComingSoon ? .secondary : .primary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            if let plugin = app.plugin(app.selection), app.enabledIDs.contains(plugin.id) {
                plugin.makeMainView()
                    .id(plugin.id)
            } else {
                ContentUnavailableView("选一个功能", systemImage: "fork.knife", description: Text("左边挑一个开始干饭。"))
            }
        }
        .onChange(of: app.selection) { _, id in
            if let id { app.settings[AppKeys.lastPlugin] = id }
        }
        .onAppear { app.mainWindow(isOpen: true) }
        .onDisappear { app.mainWindow(isOpen: false) }
    }
}
