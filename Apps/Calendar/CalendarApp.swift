import AppKit
import CalendarPlugin
import IronBowlKit
import SwiftUI

/// 独立版万年历：只依赖 IronBowlKit + CalendarPlugin，和饭碗共用同一个数据库（节假日、天气设置都共享）。
@main
struct CalendarApp: App {
    @State private var app = StandaloneCalendar()

    var body: some Scene {
        MenuBarExtra {
            CalendarPanel(app: app)
        } label: {
            CalendarMenuLabel(app: app)
        }
        .menuBarExtraStyle(.window)


        Window("饭碗万年历", id: "calendar") {
            if let model = app.plugin.model {
                CalendarMainView(model: model)
                    .frame(minWidth: 860, minHeight: 620)
                    .id(app.fontScale)
            }
        }
        .defaultSize(width: 1000, height: 700)
        .defaultLaunchBehavior(.suppressed)

        Window("万年历设置", id: "settings") {
            StandaloneSettings(app: app)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@Observable
final class StandaloneCalendar {
    let database: AppDatabase
    let settings: SettingsStore
    let workCalendar: WorkCalendar
    let plugin = CalendarPlugin()
    var now = Date()
    var settingsPage = CalendarPlugin.settingsWeatherID
    @ObservationIgnored var openWindow: ((String) -> Void)?
    @ObservationIgnored private var clock: Timer?

    var fontScale: Double { settings[SettingKey<Double>("app.fontScale", default: 1.0)] }

    init() {
        do {
            database = try AppDatabase(migrations: plugin.migrations)
        } catch {
            fatalError("打开数据库失败：\(error)")
        }
        settings = SettingsStore(database: database)
        workCalendar = WorkCalendar(database: database, settings: settings)
        DS.fontScale = settings[SettingKey<Double>("app.fontScale", default: 1.0)]
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
        // 和饭碗用同一个外观设置。
        let mode = settings[SettingKey<String>("app.appearance", default: "system")]
        NSApp?.appearance = mode == "light" ? NSAppearance(named: .aqua) : mode == "dark" ? NSAppearance(named: .darkAqua) : nil
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        Task { await workCalendar.updateIfNeeded() }
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
        .onAppear { app.openWindow = { openWindow(id: $0) } }
    }
}

/// 点菜单栏弹出的面板：左边月历，右边时间、日期、天气、农历。
struct CalendarPanel: View {
    let app: StandaloneCalendar

    var body: some View {
        VStack(spacing: 0) {
            if let model = app.plugin.model {
                CalendarPopover(model: model)
            }
            HStack {
                Spacer()
                Button("退出万年历") { NSApp.terminate(nil) }.buttonStyle(.dsGhost)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(alignment: .top) { Rectangle().fill(DS.border).frame(height: 1) }
        }
        .background(DS.canvas)
        .id(app.fontScale)
    }
}

/// 设置窗口：月历 + 天气两页。
struct StandaloneSettings: View {
    @Bindable var app: StandaloneCalendar

    var body: some View {
        let pages = app.plugin.settingsPages
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
            }
            .padding(10)
            .frame(width: 180)
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
        .frame(width: DS.s(720), height: DS.s(520))
    }
}
