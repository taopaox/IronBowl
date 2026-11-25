import AppKit
import IronBowlKit
import SwiftUI

@main
struct IronBowlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("饭碗", id: "main") {
            MainView(app: app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1120, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand(app: app)
            }
        }

        Window("设置", id: "settings") {
            SettingsView(app: app)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuPanel(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)
    }
}

/// ⌘, 打开设置窗口。
private struct SettingsCommand: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel? { AppModel.shared }

    /// 点程序坞图标时打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app?.openMainWindow?() }
        return true
    }

    /// 关掉主窗口不退出，菜单栏图标常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
