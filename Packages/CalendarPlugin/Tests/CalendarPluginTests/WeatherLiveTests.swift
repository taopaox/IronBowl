import Foundation
import Testing
@testable import CalendarPlugin

/// 联网测试：IRONBOWL_IT=1 swift test --filter weatherLive
@Test(.enabled(if: ProcessInfo.processInfo.environment["IRONBOWL_IT"] == "1"))
func weatherLive() async throws {
    let cities = try await WeatherService.searchCity("深圳")
    print("cities:", cities.prefix(3).map(\.displayName))
    let city = try #require(cities.first)
    let w = try await WeatherService.fetch(source: .openMeteo, city: city, qweatherKey: "", qweatherHost: "")
    print("now: \(w.text) \(w.temperature)°, days: \(w.days.map { "\($0.date) \($0.text) \($0.low)~\($0.high)" })")
    #expect(w.days.count == 7)
}
