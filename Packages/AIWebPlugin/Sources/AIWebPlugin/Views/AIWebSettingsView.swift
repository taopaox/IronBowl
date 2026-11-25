import IronBowlKit
import SwiftUI

struct AIWebSettingsView: View {
    @Bindable var model: AIWebModel
    @State private var editingTarget: AIEditorTarget?
    @State private var confirmReset = false
    @State private var notice: String?

    var body: some View {
        let pinned = model.pinnedApps
        DSSection("已固定到左侧 AI 目录", footer: "固定后的 AI 会显示在主窗口左侧栏「AI」目录下，点击即可在内嵌网页中使用，切走后自动保留登录态并支持墓碑休眠。") {
            if pinned.isEmpty {
                DSRow("暂无已固定的 AI", description: "可在下方列表中打开任意 AI 的固定开关，或直接新增自定义 AI。") {
                    Button("添加 AI") { editingTarget = .create }
                        .buttonStyle(.dsSecondary)
                }
            } else {
                ForEach(Array(pinned.enumerated()), id: \.element.id) { index, app in
                    let suspended = model.isSuspended(appID: app.id)
                    let desc = [app.url, app.neverSuspend ? "免休眠" : nil, suspended ? "已休眠" : nil]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    DSRow(app.name, description: desc) {
                        HStack(spacing: 4) {
                            AILogoView(logo: app.logo, logoStore: model.logoStore, size: DS.s(18), cornerRadius: 4)
                                .padding(.trailing, 4)

                            Button { model.movePinnedApp(id: app.id, delta: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.dsGhost)
                                .disabled(index == 0)
                                .help("上移")

                            Button { model.movePinnedApp(id: app.id, delta: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.dsGhost)
                                .disabled(index == pinned.count - 1)
                                .help("下移")

                            Button { editingTarget = .edit(app) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.dsGhost)
                                .help("编辑")

                            Button { model.setPinned(false, id: app.id) } label: { Image(systemName: "pin.slash") }
                                .buttonStyle(.dsGhost)
                                .help("取消固定")
                        }
                    }
                }
            }
        }

        DSSection("全部 AI 管理", footer: "支持新增自定义 AI，或修改任意 AI 的官方/自定义 Logo、名称与网页链接。") {
            ForEach(model.apps) { app in
                DSRow(app.name, description: "\(app.category.displayName) · \(app.url)") {
                    HStack(spacing: 8) {
                        AILogoView(logo: app.logo, logoStore: model.logoStore, size: DS.s(18), cornerRadius: 4)

                        DSToggle(isOn: Binding(
                            get: { app.isPinned },
                            set: { model.setPinned($0, id: app.id) }
                        ))
                        .help("是否固定到左侧 AI 目录")

                        Button { editingTarget = .edit(app) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.dsGhost)
                            .help("编辑")

                        Button { model.deleteApp(id: app.id) } label: {
                            Image(systemName: "trash").foregroundStyle(DS.danger)
                        }
                        .buttonStyle(.dsGhost)
                        .help("删除")
                    }
                }
            }

            DSRow("新增自定义 AI") {
                Button("添加 AI") { editingTarget = .create }
                    .buttonStyle(.dsSecondary)
            }
        }
        .sheet(item: $editingTarget) { target in
            AIAppEditorSheet(model: model, editingApp: target.app) {
                editingTarget = nil
            }
        }

        DSSection("预设与内存") {
            DSRow("补齐缺失的内置 AI", description: notice ?? "只补回你删掉的官方内置 AI，不会覆盖已经修改的条目和自定义 AI。") {
                Button("补齐内置 AI") {
                    let added = model.restoreMissingPresets()
                    notice = added > 0 ? "已补回 \(added) 个内置 AI" : "所有内置 AI 都已存在"
                }
                .buttonStyle(.dsSecondary)
            }

            DSRow("恢复默认 AI 列表", description: "重置为内置的 20 个主流 AI 及其官方 Logo 与默认固定项。") {
                Button("恢复默认") { confirmReset = true }
                    .buttonStyle(.dsSecondary)
            }

            DSRow("网页休眠策略", description: "后台休眠时长、最多保活页数在「设置 → 网页与内存」中统一调整。") {
                Button("前往「网页与内存」") { model.openSettings("web") }
                    .buttonStyle(.dsSecondary)
            }
        }
        .alert("恢复默认 AI 列表？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) {
                model.resetToPresets()
                notice = "已恢复默认 AI 列表"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会移除你手动添加的自定义 AI 并重置所有修改，仅保留内置 20 个主流 AI。")
        }
    }
}
