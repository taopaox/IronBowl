import IronBowlKit
import SwiftUI

struct FeishuSettingsView: View {
    @Bindable var model: FeishuModel
    @State private var homeURLInput = ""
    @State private var homeURLError: String?
    @State private var editingTarget: PinSheetTarget?
    @State private var confirmClearCache = false
    @State private var cacheNotice: String?

    private struct PinSheetTarget: Identifiable {
        let id: String
        let page: FeishuPinnedPage?
    }

    var body: some View {
        DSSection("飞书知识库", footer: "点击主窗口左侧栏「飞书知识库」时加载的默认网址。") {
            DSRow("主页地址", description: homeURLError ?? "默认为 \(FeishuURL.defaultHomeURL)") {
                HStack(spacing: 6) {
                    TextField(FeishuURL.defaultHomeURL, text: $homeURLInput)
                        .textFieldStyle(.ds)
                        .frame(width: DS.s(260))
                        .onSubmit { applyHomeURL() }
                    Button("保存") { applyHomeURL() }
                        .buttonStyle(.dsSecondary)
                    Button("恢复默认") {
                        homeURLInput = FeishuURL.defaultHomeURL
                        homeURLError = nil
                        model.homeURL = FeishuURL.defaultHomeURL
                    }
                    .buttonStyle(.dsGhost)
                }
            }
        }
        .onAppear { homeURLInput = model.homeURL }

        DSSection("左侧固定网页", footer: "固定后的网页会出现在主窗口左侧栏，切走后保留浏览状态；后台超时后自动休眠省内存。") {
            if model.pinnedPages.isEmpty {
                DSRow("还没有固定网页", description: "可在飞书网页顶栏点「固定到左侧」，或直接在这里添加。") {
                    Button("添加固定网页") {
                        editingTarget = PinSheetTarget(id: "new", page: nil)
                    }
                    .buttonStyle(.dsSecondary)
                }
            } else {
                let pages = model.pinnedPages
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    let suspended = model.isSuspended(pageID: page.id)
                    let desc = [page.url, page.neverSuspend ? "免休眠" : nil, suspended ? "已休眠" : nil]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    DSRow(page.title, description: desc) {
                        HStack(spacing: 4) {
                            Image(systemName: page.systemImage)
                                .font(DS.font(13))
                                .foregroundStyle(DS.textSecondary)
                                .padding(.trailing, 4)

                            Button { model.movePin(id: page.id, delta: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.dsGhost)
                                .disabled(index == 0)
                                .help("上移")

                            Button { model.movePin(id: page.id, delta: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.dsGhost)
                                .disabled(index == pages.count - 1)
                                .help("下移")

                            Button {
                                editingTarget = PinSheetTarget(id: page.id, page: page)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.dsGhost)
                            .help("编辑")

                            Button {
                                model.unpin(id: page.id)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(DS.danger)
                            }
                            .buttonStyle(.dsGhost)
                            .help("取消固定")
                        }
                    }
                }

                DSRow("新增固定网页") {
                    Button("添加固定网页") {
                        editingTarget = PinSheetTarget(id: "new", page: nil)
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        }
        .sheet(item: $editingTarget) { target in
            PinPageEditor(
                model: model,
                editingPage: target.page,
                initialTitle: target.page?.title ?? "",
                initialURL: target.page?.url ?? FeishuURL.defaultHomeURL,
                initialIcon: target.page?.systemImage ?? "doc.text",
                initialNeverSuspend: target.page?.neverSuspend ?? false,
                onClose: { editingTarget = nil }
            )
        }

        DSSection("浏览器与休眠") {
            DSRow("网页休眠策略", description: "全局后台休眠时长、最多保活页数在「设置 → 网页与内存」中统一调整。") {
                Button("前往「网页与内存」") { model.openSettings("web") }
                    .buttonStyle(.dsSecondary)
            }
            DSRow("刷新已打开网页", description: "重新加载飞书主页和当前活跃的固定网页。") {
                Button("全部刷新") { model.reloadAllSessions() }
                    .buttonStyle(.dsSecondary)
            }
            DSRow("清除登录缓存", description: cacheNotice ?? "飞书主页与固定网页共享登录 Cookie，异常时可清除重登。") {
                Button("清除登录缓存") { confirmClearCache = true }
                    .buttonStyle(.dsSecondary)
            }
        }
        .alert("清除登录缓存？", isPresented: $confirmClearCache) {
            Button("清除", role: .destructive) {
                Task {
                    await model.clearWebsiteData()
                    cacheNotice = "已清除缓存并刷新页面"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会清空所有内嵌网页的 Cookie 与本地存储，需要重新登录。")
        }
    }

    private func applyHomeURL() {
        guard let normalized = FeishuURL.normalize(homeURLInput) else {
            homeURLError = "网址格式无效，请以 https:// 开头"
            return
        }
        homeURLError = nil
        homeURLInput = normalized.absoluteString
        model.homeURL = normalized.absoluteString
    }
}
