import IronBowlKit
import SwiftUI
import Testing

private final class DummySidebarPlugin: IronBowlPlugin {
    let id: String
    let title: String
    let systemImage = "doc"
    let customSidebarTitle: String?
    let sidebarSection: String?

    init(id: String, title: String, sidebarTitle: String? = nil, sidebarSection: String? = nil) {
        self.id = id
        self.title = title
        self.customSidebarTitle = sidebarTitle
        self.sidebarSection = sidebarSection
    }

    var sidebarTitle: String {
        customSidebarTitle ?? title
    }

    func makeMainView() -> AnyView {
        AnyView(EmptyView())
    }
}

private final class DefaultSidebarPlugin: IronBowlPlugin {
    let id: String
    let title: String
    let systemImage = "star"

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    func makeMainView() -> AnyView {
        AnyView(EmptyView())
    }
}

@MainActor @Test func sidebarPluginDefaultsFallbackToTitleAndNoSection() {
    let plugin = DefaultSidebarPlugin(id: "default", title: "默认标题")
    #expect(plugin.sidebarTitle == "默认标题")
    #expect(plugin.sidebarSection == nil)
}

@MainActor @Test func sidebarPluginGroupingPartitionsAndPreservesOrder() {
    let plugins: [IronBowlPlugin] = [
        DummySidebarPlugin(id: "daily", title: "禅道日志", sidebarTitle: "日报", sidebarSection: "汇报"),
        DefaultSidebarPlugin(id: "cal", title: "万年历"),
        DummySidebarPlugin(id: "blank", title: "空白分组", sidebarSection: "   "),
        DummySidebarPlugin(id: "weekly", title: "周报", sidebarSection: "汇报"),
        DummySidebarPlugin(id: "other", title: "其他", sidebarSection: "扩展"),
        DummySidebarPlugin(id: "monthly", title: "月报", sidebarSection: " 汇报 "),
    ]

    let partitioned = SidebarPluginGrouping.partition(plugins)
    #expect(partitioned.ungrouped.map(\.id) == ["cal", "blank"])
    #expect(partitioned.sections.map(\.title) == ["汇报", "扩展"])
    #expect(partitioned.sections[0].plugins.map(\.id) == ["daily", "weekly", "monthly"])
    #expect(partitioned.sections[0].plugins.map(\.sidebarTitle) == ["日报", "周报", "月报"])
    #expect(partitioned.sections[1].plugins.map(\.id) == ["other"])
}
