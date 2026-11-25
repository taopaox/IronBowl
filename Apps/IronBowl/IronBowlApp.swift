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
                .onAppear { delegate.app = app }
        }
        .defaultSize(width: 1080, height: 760)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuPanel(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(app: app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    /// 点程序坞图标时打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app?.openMainWindow?() }
        return true
    }

    /// 关掉主窗口不退出，菜单栏图标常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
