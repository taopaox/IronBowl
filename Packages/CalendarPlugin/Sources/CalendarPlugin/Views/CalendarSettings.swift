import IronBowlKit
import SwiftUI

struct CalendarDisplaySettings: View {
    let model: CalendarModel

    var body: some View {
        let s = model.settings
        DSSection("月历", footer: "节假日和调休数据在「工作时间」里设置，万年历和禅道日志共用。") {
            DSRow("每周第一天") {
                DSPicker(selection: s.binding(CalendarKeys.firstWeekday), options: [(2, "周一"), (1, "周日")])
            }
        }
        DSSection("菜单栏日历", footer: "菜单栏单独显示一个日历，点开就是月历。按住 ⌘ 可以拖动调整它在菜单栏的位置。") {
            DSRow("在菜单栏显示日历") { DSToggle(isOn: s.binding(CalendarKeys.menuBarEnabled)) }
            if s[CalendarKeys.menuBarEnabled] {
                DSRow("显示内容", description: "预览：\(model.menuBarText)") { EmptyView() }
                DSRow("天气") { DSToggle(isOn: s.binding(CalendarKeys.menuBarWeather)) }
                DSRow("日期") { DSToggle(isOn: s.binding(CalendarKeys.menuBarDate)) }
                DSRow("星期") { DSToggle(isOn: s.binding(CalendarKeys.menuBarWeekday)) }
                DSRow("农历") { DSToggle(isOn: s.binding(CalendarKeys.menuBarLunar)) }
                DSRow("时间") { DSToggle(isOn: s.binding(CalendarKeys.menuBarTime)) }
            }
        }
    }
}

struct WeatherSettings: View {
    let model: CalendarModel
    @State private var query = ""
    @State private var results: [City] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        let s = model.settings
        DSSection("城市") {
            DSRow("当前城市", description: s[CalendarKeys.city]?.displayName ?? "还没选") {
                if s[CalendarKeys.city] != nil {
                    Button("刷新天气") { Task { await model.refreshWeather() } }.buttonStyle(.dsSecondary)
                }
            }
            DSRow("搜索城市", description: searchError ?? "输入中文或拼音，比如：深圳、hangzhou。") {
                HStack(spacing: 6) {
                    TextField("", text: $query, prompt: Text("城市名")).textFieldStyle(.ds).frame(width: 200)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        if searching { ProgressView().controlSize(.small).tint(DS.onPrimary) } else { Text("搜索") }
                    }
                    .buttonStyle(.dsPrimary)
                }
            }
            ForEach(results) { city in
                DSRow(city.name, description: city.region) {
                    Button("选这个") {
                        s[CalendarKeys.city] = city
                        results = []
                        query = ""
                        Task { await model.refreshWeather() }
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
        }

        DSSection("数据源", footer: "Open-Meteo 免费、无需注册；和风天气的数据更贴近国内天气预报，需要在和风控制台申请密钥和 API Host。") {
            DSRow("天气数据源") {
                DSPicker(selection: s.binding(CalendarKeys.weatherSource), options: WeatherSource.allCases.map { ($0, $0.displayName) })
            }
            if s[CalendarKeys.weatherSource] == .qweather {
                DSRow("和风密钥 (Key)") {
                    TextField("", text: s.binding(CalendarKeys.qweatherKey)).textFieldStyle(.ds).frame(width: 280)
                }
                DSRow("API Host", description: "和风控制台里显示的专属域名。") {
                    TextField("", text: s.binding(CalendarKeys.qweatherHost)).textFieldStyle(.ds).frame(width: 280)
                }
            }
            DSRow("自动刷新间隔") {
                DSStepper(intValue: s.binding(CalendarKeys.refreshMinutes), in: 10...240, step: 10) { "\($0) 分钟" }
            }
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await WeatherService.searchCity(q)
            searchError = results.isEmpty ? "没找到这个城市" : nil
        } catch {
            searchError = error.localizedDescription
        }
    }
}
