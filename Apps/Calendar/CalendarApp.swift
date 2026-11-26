import AppKit
import CalendarPlugin
import IronBowlKit
import SwiftUI

/// 独立版万年历：只依赖 IronBowlKit + CalendarPlugin，和饭碗共用同一个数据库（节假日、天气设置都共享）。
@main
struct CalendarApp: App {
    @NSApplicationDelegateAdaptor(CalendarAppDelegate.self) private var delegate
    @State private var app = StandaloneCalendar()

    var body: some Scene {
        MenuBarExtra {
            CalendarPanel(app: app)
                .menuBarPopoverDismissable()
        } label: {
            CalendarMenuLabel(app: app)
        }
        .menuBarExtraStyle(.window)


        Window("饭碗万年历", id: "calendar") {
            if let model = app.plugin.model {
                CalendarMainView(model: model, versionText: Bundle.main.displayVersion)
                    .frame(minWidth: 860, minHeight: 620)
                    .id(app.fontScale)
                    .environment(\.locale, CN.locale)
            }
        }
        .defaultSize(width: 1000, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于饭碗万年历") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: AppBrand.aboutCredits(),
                    ])
                }
            }
            CommandGroup(replacing: .appSettings) {
                CalendarSettingsCommand(app: app)
            }
        }

        Window("万年历设置", id: "settings") {
            StandaloneSettings(app: app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct CalendarSettingsCommand: View {
    let app: StandaloneCalendar
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
    }
}

final class CalendarAppDelegate: NSObject, NSApplicationDelegate {
    var app: StandaloneCalendar? { StandaloneCalendar.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        app?.applyAppearance()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app?.openWindow?("calendar") }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@Observable
final class StandaloneCalendar {
    nonisolated(unsafe) static weak var shared: StandaloneCalendar?
    let database: AppDatabase
    let settings: SettingsStore
    let workCalendar: WorkCalendar
    let plugin = CalendarPlugin()
    var now = Date()
    var settingsPage = CalendarPlugin.settingsDisplayID
    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored private var clock: Timer?

    var fontScale: Double { settings[AppSharedKeys.fontScale] }

    init() {
        defer { StandaloneCalendar.shared = self }
        do {
            database = try AppDatabase(migrations: plugin.migrations)
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
        settings = SettingsStore(database: database)
        workCalendar = WorkCalendar(database: database, settings: settings)
        DS.fontScale = settings[AppSharedKeys.fontScale]
        let context = PluginContext(
            database: database, settings: settings, reminders: ReminderCenter(),
            workCalendar: workCalendar, providers: AIProviderStore(settings: settings),
            openPlugin: { [weak self] _ in self?.openWindow?("calendar"); NSApp.activate() },
            openSettings: { [weak self] page in
                if let page { self?.settingsPage = page }
                self?.openWindow?("settings")
                NSApp.activate()
            }
        )
        plugin.start(context: context)
        applyAppearance()
        settings.onExternalChange = { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            DS.fontScale = self.settings[AppSharedKeys.fontScale]
            self.plugin.model?.syncExternalChanges()
        }
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        Task { await workCalendar.updateIfNeeded() }
    }

    func applyAppearance() {
        NSApp?.appearance = settings[AppSharedKeys.appearance].nsAppearance
    }
}

/// 菜单栏：天气 + 日期 + 星期 + 时间（和饭碗里的菜单栏日历同一个组件）。
struct CalendarMenuLabel: View {
    let app: StandaloneCalendar
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let model = app.plugin.model { CalendarMenuBarLabel(model: model) } else { Text("万年历") }
        }
        .onAppear {
            app.openWindow = { openWindow(id: $0) }
            app.applyAppearance()
        }
    }
}

/// 点菜单栏弹出的面板：左边月历，右边时间、日期、天气、农历。
struct CalendarPanel: View {
    let app: StandaloneCalendar

    var body: some View {
        Group {
            if let model = app.plugin.model {
                CalendarPopover(model: model, onQuit: { NSApp.terminate(nil) })
            }
        }
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }
}

/// 设置窗口：月历 + 状态栏 + 外观 + 节假日 + 天气。
struct StandaloneSettings: View {
    @Bindable var app: StandaloneCalendar

    private var pages: [SettingsPage] {
        let pluginPages = app.plugin.settingsPages.map { page in
            if page.id == CalendarPlugin.settingsAppearanceID, let model = app.plugin.model {
                return SettingsPage(id: page.id, title: page.title, systemImage: page.systemImage) {
                    AnyView(StandaloneAppearanceSettings(app: app, model: model))
                }
            }
            return page
        }
        return pluginPages + [
            SettingsPage(id: "about", title: "关于", systemImage: "info.circle") {
                AnyView(StandaloneAboutSettings())
            }
        ]
    }

    var body: some View {
        let pages = pages
        let current = pages.first { $0.id == app.settingsPage } ?? pages.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                DSSidebarSection("万年历")
                ForEach(pages) { page in
                    DSSidebarItem(page.title, systemImage: page.systemImage, selected: page.id == current?.id) {
                        app.settingsPage = page.id
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("饭碗万年历 \(Bundle.main.displayVersion)")
                        .font(DS.font(11.5))
                        .monospacedDigit()
                        .foregroundStyle(DS.textTertiary)
                        .help("当前版本 \(Bundle.main.fullVersion)")
                    DSSloganView(style: .sidebar)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            .padding(10)
            .frame(width: 190)
            .background(DS.sidebar)
            Rectangle().fill(DS.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let current { current.makeView().id(current.id) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.groupBackground)
        }
        .frame(width: DS.s(760), height: DS.s(540))
        .id(app.fontScale)
        .environment(\.locale, CN.locale)
    }
}

private struct StandaloneAppearanceSettings: View {
    let app: StandaloneCalendar
    let model: CalendarModel

    var body: some View {
        CalendarAppearanceSettings(model: model, showGlobalAppearanceLink: false)
        DSAppearanceSettingsView(
            settings: app.settings,
            onAppearanceChange: { app.applyAppearance() },
            onFontScaleChange: { DS.fontScale = app.settings[AppSharedKeys.fontScale] }
        )
    }
}

private struct StandaloneAboutSettings: View {
    @State private var copied = false

    var body: some View {
        DSSection("关于") {
            DSBlockRow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image("AppLogo")
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: DS.s(36), height: DS.s(36))

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("饭碗万年历")
                                    .font(DS.font(15, .semibold))
                                Text(Bundle.main.displayVersion)
                                    .font(DS.font(11, .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(DS.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(DS.well, in: .capsule)
                            }
                            Text("\(AppBrand.name) \(AppBrand.englishName) 独立桌面组件")
                                .font(DS.caption)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }

                    DSSloganView(style: .banner)
                }
            }
            DSRow("当前版本", description: "饭碗万年历 · \(Bundle.main.fullVersion)") {
                Button(copied ? "已复制" : "复制版本信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("饭碗万年历 \(Bundle.main.fullVersion)", forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .buttonStyle(.dsSecondary)
            }
        }
    }
}
