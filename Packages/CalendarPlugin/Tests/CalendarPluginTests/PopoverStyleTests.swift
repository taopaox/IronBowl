import Foundation
import IronBowlKit
import SwiftUI
import Testing
@testable import CalendarPlugin

@Test func popoverStyleCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(CalendarPopoverStyle.allCases.count == 6)
    #expect(CalendarPopoverStyle.system.displayName == "跟随系统")
    #expect(CalendarPopoverStyle.appearance.displayName == "跟随外观")
    for style in CalendarPopoverStyle.allCases {
        let data = try encoder.encode(style)
        let decoded = try decoder.decode(CalendarPopoverStyle.self, from: data)
        #expect(decoded == style)
        #expect(!style.displayName.isEmpty)
    }
}

@Test func popoverStylePaletteResolution() {
    let appModes: [AppearanceMode] = [.system, .light, .dark]
    let systemSchemes: [ColorScheme] = [.light, .dark]

    // 跟随系统：始终跟随系统深浅色，忽略主应用外观强制覆盖
    for appMode in appModes {
        #expect(!CalendarPopoverStyle.system.palette(appAppearance: appMode, systemColorScheme: .light).usesDarkGrid)
        #expect(CalendarPopoverStyle.system.palette(appAppearance: appMode, systemColorScheme: .dark).usesDarkGrid)
    }

    // 跟随外观：随主应用外观设置（日间→简约白，夜间→深邃黑，跟随系统→随系统深浅色）
    for scheme in systemSchemes {
        #expect(!CalendarPopoverStyle.appearance.palette(appAppearance: .light, systemColorScheme: scheme).usesDarkGrid)
        #expect(CalendarPopoverStyle.appearance.palette(appAppearance: .dark, systemColorScheme: scheme).usesDarkGrid)
        #expect(
            CalendarPopoverStyle.appearance.palette(appAppearance: .system, systemColorScheme: scheme).usesDarkGrid
                == (scheme == .dark)
        )
    }

    // 固定主题：不受主应用外观与系统深浅色影响
    for appMode in appModes {
        for scheme in systemSchemes {
            for style in [CalendarPopoverStyle.white, .red, .blue] {
                #expect(!style.palette(appAppearance: appMode, systemColorScheme: scheme).usesDarkGrid)
            }
            #expect(CalendarPopoverStyle.black.palette(appAppearance: appMode, systemColorScheme: scheme).usesDarkGrid)
        }
    }

    #expect(CalendarPopoverStyle.red.palette(appAppearance: .system, systemColorScheme: .light).sidebarDivider == nil)
    #expect(CalendarPopoverStyle.blue.palette(appAppearance: .system, systemColorScheme: .light).sidebarDivider == nil)
    #expect(CalendarPopoverStyle.white.palette(appAppearance: .system, systemColorScheme: .light).sidebarDivider != nil)
    #expect(CalendarPopoverStyle.black.palette(appAppearance: .system, systemColorScheme: .dark).sidebarDivider != nil)
}

@MainActor @Test func popoverStylePersistsInSettingsStore() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "ib-cal-style-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let db = try AppDatabase(url: url, migrations: [])
    let settings = SettingsStore(database: db)

    #expect(settings[CalendarKeys.popoverStyle] == .appearance)

    settings[CalendarKeys.popoverStyle] = .system
    #expect(settings[CalendarKeys.popoverStyle] == .system)

    let reloaded = SettingsStore(database: db)
    #expect(reloaded[CalendarKeys.popoverStyle] == .system)

    reloaded[CalendarKeys.popoverStyle] = .red
    #expect(reloaded[CalendarKeys.popoverStyle] == .red)

    reloaded[CalendarKeys.popoverStyle] = .black
    #expect(reloaded[CalendarKeys.popoverStyle] == .black)

    let reloadedAgain = SettingsStore(database: db)
    #expect(reloadedAgain[CalendarKeys.popoverStyle] == .black)

    reloadedAgain[CalendarKeys.popoverStyle] = .appearance
    #expect(reloadedAgain[CalendarKeys.popoverStyle] == .appearance)
}
