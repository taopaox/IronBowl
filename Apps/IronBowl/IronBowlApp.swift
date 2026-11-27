import AppKit
import CalendarPlugin
import IronBowlKit
import SwiftUI

@main
struct IronBowlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        let isCalendarMenuInserted = app.calendarMenuShown
        let isDashboardMenuInserted = !app.menuBarCardSegments.isEmpty

        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于饭碗") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: AppBrand.aboutCredits(),
                    ])
                }
                Divider()
                Button("检查更新…") {
                    app.updater.checkForUpdates()
                }
                .disabled(!app.updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    app.openSettings()
                }
                .keyboardShortcut(",")
            }
            CommandGroup(after: .textEditing) {
                Button("命令面板与全局搜索…") {
                    app.commandPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        // 右侧信息仪表卡：无信息项时自动隐藏，仅留独立 Logo。
        MenuBarExtra(isInserted: Binding(get: { isDashboardMenuInserted }, set: { _ in })) {
            MenuPanel(app: app)
                .menuBarPopoverDismissable()
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)

        // 菜单栏日历：天气 + 日期 + 星期 + 时间，点开是月历。
        MenuBarExtra(isInserted: Binding(get: { isCalendarMenuInserted }, set: { _ in })) {
            if let model = app.calendarModel {
                CalendarPopover(model: model)
                    .id(app.fontScale)
                    .environment(\.locale, CN.locale)
                    .menuBarPopoverDismissable()
            }
        } label: {
            if let model = app.calendarModel {
                CalendarMenuBarLabel(model: model)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// 主工作台窗口控制器：点关闭按钮时隐藏保活不销毁 `MainView` / `HomeView`，实现状态栏秒开。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let app: AppModel
    private var window: NSWindow?
    var allowClose = false

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    var isFrontmostAndVisible: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return NSApp.isActive && (window.isKeyWindow || NSApp.mainWindow === window)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "饭碗"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.toolbarStyle = .unifiedCompact
        win.minSize = NSSize(width: 860, height: 600)
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = false
        win.center()
        win.setFrameAutosaveName("IronBowlMainWindow")
        let hosting = NSHostingController(rootView: MainView(app: app))
        win.contentViewController = hosting
        win.delegate = self
        self.window = win
        return win
    }

    func show() {
        let win = ensureWindow()
        win.appearance = NSApp.appearance
        app.mainWindow(isOpen: true)
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
        app.mainWindow(isOpen: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        hide()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        app.mainWindow(isOpen: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        app.mainWindow(isOpen: true)
    }
}

/// 设置窗口控制器：按需创建并复用 `NSWindow`。
@MainActor
final class SettingsWindowController: NSObject {
    private let app: AppModel
    private var window: NSWindow?

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    func show() {
        let win: NSWindow
        if let existing = window {
            win = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: DS.s(900), height: DS.s(660)),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            created.title = "设置"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: SettingsView(app: app))
            hosting.sizingOptions = [.preferredContentSize]
            created.contentViewController = hosting
            created.center()
            self.window = created
            win = created
        }
        win.appearance = NSApp.appearance
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel? { AppModel.shared }
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var logoStatusItemController: LogoStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let app {
            let mainCtrl = MainWindowController(app: app)
            let settingsCtrl = SettingsWindowController(app: app)
            let logoCtrl = LogoStatusItemController(app: app)
            self.mainWindowController = mainCtrl
            self.settingsWindowController = settingsCtrl
            self.logoStatusItemController = logoCtrl

            app.openMainWindow = { [weak mainCtrl] in mainCtrl?.show() }
            app.hideMainWindow = { [weak mainCtrl] in mainCtrl?.hide() }
            app.isMainWindowFrontmost = { [weak mainCtrl] in mainCtrl?.isFrontmostAndVisible ?? false }
            app.openSettingsWindow = { [weak settingsCtrl] in settingsCtrl?.show() }

            app.applyDockMode()
            app.applyAppearance()
            logoCtrl.start()
            app.calendarModel?.refreshStandaloneCalendarState()
        }
        CalendarMenuBarPolicy.postStandaloneProbe()
    }

    /// 点程序坞图标时打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app?.showMainWindow() }
        return true
    }

    /// 关掉主窗口不退出，菜单栏图标常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.allowClose = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        logoStatusItemController?.stop()
        app?.settings.flushDeferredWrites()
    }
}
