import IronBowlKit
import SwiftUI

/// 首页「今天」：居中问候 + 快捷标签 + 输入框 + 小卡片。
struct HomeView: View {
    let app: AppModel
    @State private var input = ""
    @State private var sending = false
    @State private var result: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer().frame(height: 80)
                Text(greeting).font(DS.heroTitle)

                let actions = app.enabledPlugins.flatMap(\.quickActions)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions) { a in
                            Button { a.action() } label: { Text(a.title) }
                                .buttonStyle(.dsChip)
                        }
                    }
                }

                inputBox

                if let result {
                    DSBanner(result.hasPrefix("❌") ? .danger : .success, result.replacingOccurrences(of: "❌ ", with: ""))
                }

                let cards = coreCards + app.enabledPlugins.flatMap(\.homeCards)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(cards) { card in
                        Button { card.action?() } label: {
                            DSMetric(card.label, value: card.value(), detail: card.detail())
                        }
                        .buttonStyle(.plain)
                        .disabled(card.action == nil)
                    }
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var greeting: String {
        let _ = app.now
        let h = Calendar.current.component(.hour, from: Date())
        let part = switch h {
        case 5..<11: "早上好"
        case 11..<13: "中午好"
        case 13..<18: "下午好"
        default: "晚上好"
        }
        return "饭碗，\(part)"
    }

    private var inputBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("今天做了什么？说一句，帮你记成日志。比如：下午和产品对需求 2 小时")
                        .font(DS.body).foregroundStyle(DS.textTertiary)
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $input)
                    .font(DS.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 54, maxHeight: 120)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        Task { await send() }
                        return .handled
                    }
            }
            HStack(spacing: 10) {
                Text("Enter 发送 · Shift+Enter 换行").font(DS.caption).foregroundStyle(DS.textTertiary)
                Spacer()
                DSPicker(selection: Binding(get: { app.providers.defaultKind }, set: { app.providers.defaultKind = $0 }),
                         options: AIProviderKind.allCases.map { ($0, $0.displayName) })
                Button {
                    Task { await send() }
                } label: {
                    Group {
                        if sending { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up").font(DS.font(14, .bold)) }
                    }
                    .foregroundStyle(DS.onPrimary)
                    .frame(width: 30, height: 30)
                    .background(DS.primaryFill.opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }
        }
        .padding(14)
        .background(DS.card, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? DS.borderStrong : DS.border) }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        for plugin in app.enabledPlugins {
            if let r = await plugin.handleHomeInput(text) {
                result = r
                if !r.hasPrefix("❌") { input = "" }
                return
            }
        }
        result = "❌ 没有插件能处理这句话"
    }

    private var coreCards: [HomeCard] {
        let cal = app.workCalendar
        return [
            HomeCard(id: "core.lunar", label: Date().formatted(.dateTime.month().day().weekday(.wide)),
                     value: { WorkCalendar.lunarString(Date()) },
                     detail: {
                         guard let h = cal.nextHoliday() else { return nil }
                         let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: h.date).day ?? 0
                         return "距\(h.name) \(days) 天"
                     }),
            HomeCard(id: "core.offwork", label: "下班",
                     value: {
                         let _ = app.now
                         guard cal.isWorkday(Date()), let end = cal.workEnd(), end > Date() else { return "已下班" }
                         return countdown(to: end) + " 后"
                     },
                     detail: { "\(app.settings[WorkCalendar.startKey])–\(app.settings[WorkCalendar.endKey])" }),
        ]
    }
}
