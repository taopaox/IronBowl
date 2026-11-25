import Foundation
import IronBowlKit

public nonisolated enum WeatherSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case openMeteo, qweather
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .openMeteo: "Open-Meteo（免费，无需注册）"
        case .qweather: "和风天气（需要密钥）"
        }
    }
}

public nonisolated struct WeatherDay: Sendable, Codable, Hashable {
    public let date: String // yyyy-MM-dd
    public let text: String
    public let symbol: String
    public let high: Double
    public let low: Double
}

public nonisolated struct WeatherSnapshot: Sendable, Codable, Hashable {
    public let city: String
    public let temperature: Double
    public let text: String
    public let symbol: String
    public let days: [WeatherDay]
    public let fetchedAt: Date

    public func day(_ key: String) -> WeatherDay? { days.first { $0.date == key } }
}

public nonisolated struct City: Sendable, Codable, Hashable, Identifiable {
    public let name: String
    public let region: String
    public let latitude: Double
    public let longitude: Double
    public var id: String { "\(name)-\(latitude)-\(longitude)" }
    public var displayName: String { region.isEmpty ? name : "\(name)，\(region)" }
}

public nonisolated enum WeatherError: LocalizedError, Sendable {
    case noCity, missingKey, bad(String)
    public var errorDescription: String? {
        switch self {
        case .noCity: "还没选城市"
        case .missingKey: "和风天气需要在设置里填写密钥"
        case .bad(let s): "天气数据获取失败：\(s)"
        }
    }
}

/// 天气数据：Open-Meteo（默认，免费）或和风天气（填密钥）。
public nonisolated enum WeatherService {
    static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("IronBowl/0.2", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw WeatherError.bad("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return data
    }

    /// 城市搜索（Open-Meteo 地理编码，免费）。
    @concurrent
    public static func searchCity(_ query: String) async throws -> [City] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                        .init(name: "language", value: "zh"), .init(name: "format", value: "json")]
        struct R: Decodable {
            struct Item: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country: String? }
            let results: [Item]?
        }
        let r = try JSONDecoder().decode(R.self, from: try await get(c.url!))
        return (r.results ?? []).map {
            City(name: $0.name, region: [$0.admin1, $0.country].compactMap { $0 }.joined(separator: "，"),
                 latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    @concurrent
    public static func fetch(source: WeatherSource, city: City, qweatherKey: String, qweatherHost: String) async throws -> WeatherSnapshot {
        switch source {
        case .openMeteo: return try await openMeteo(city)
        case .qweather: return try await qweather(city, key: qweatherKey, host: qweatherHost)
        }
    }

    static func openMeteo(_ city: City) async throws -> WeatherSnapshot {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(city.latitude)), .init(name: "longitude", value: String(city.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"),
        ]
        struct R: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable { let time: [String]; let weather_code: [Int]; let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let r = try JSONDecoder().decode(R.self, from: try await get(c.url!))
        let now = wmo(r.current.weather_code)
        let days = r.daily.time.indices.map { i in
            let w = wmo(r.daily.weather_code[i])
            return WeatherDay(date: r.daily.time[i], text: w.text, symbol: w.symbol,
                              high: r.daily.temperature_2m_max[i], low: r.daily.temperature_2m_min[i])
        }
        return WeatherSnapshot(city: city.name, temperature: r.current.temperature_2m, text: now.text, symbol: now.symbol,
                               days: days, fetchedAt: Date())
    }

    static func qweather(_ city: City, key: String, host: String) async throws -> WeatherSnapshot {
        guard !key.isEmpty else { throw WeatherError.missingKey }
        let h = host.isEmpty ? "devapi.qweather.com" : host
        let loc = String(format: "%.2f,%.2f", city.longitude, city.latitude)
        struct Now: Decodable { struct N: Decodable { let temp: String; let text: String }; let code: String; let now: N? }
        struct Daily: Decodable {
            struct D: Decodable { let fxDate: String; let textDay: String; let tempMax: String; let tempMin: String }
            let code: String; let daily: [D]?
        }
        let nowURL = URL(string: "https://\(h)/v7/weather/now?location=\(loc)&key=\(key)")!
        let dailyURL = URL(string: "https://\(h)/v7/weather/7d?location=\(loc)&key=\(key)")!
        let now = try JSONDecoder().decode(Now.self, from: try await get(nowURL))
        let daily = try JSONDecoder().decode(Daily.self, from: try await get(dailyURL))
        guard now.code == "200", let n = now.now, daily.code == "200" else { throw WeatherError.bad("和风返回 \(now.code)/\(daily.code)") }
        return WeatherSnapshot(
            city: city.name, temperature: Double(n.temp) ?? 0, text: n.text, symbol: symbol(forText: n.text),
            days: (daily.daily ?? []).map {
                WeatherDay(date: $0.fxDate, text: $0.textDay, symbol: symbol(forText: $0.textDay),
                           high: Double($0.tempMax) ?? 0, low: Double($0.tempMin) ?? 0)
            },
            fetchedAt: Date()
        )
    }

    /// WMO 天气代码 → 中文 + SF Symbol。
    static func wmo(_ code: Int) -> (text: String, symbol: String) {
        switch code {
        case 0: ("晴", "sun.max")
        case 1, 2: ("多云", "cloud.sun")
        case 3: ("阴", "cloud")
        case 45, 48: ("雾", "cloud.fog")
        case 51, 53, 55: ("毛毛雨", "cloud.drizzle")
        case 56, 57, 66, 67: ("冻雨", "cloud.sleet")
        case 61: ("小雨", "cloud.rain")
        case 63: ("中雨", "cloud.rain")
        case 65: ("大雨", "cloud.heavyrain")
        case 71: ("小雪", "cloud.snow")
        case 73: ("中雪", "cloud.snow")
        case 75, 77: ("大雪", "cloud.snow")
        case 80, 81: ("阵雨", "cloud.sun.rain")
        case 82: ("强阵雨", "cloud.heavyrain")
        case 85, 86: ("阵雪", "cloud.snow")
        case 95: ("雷阵雨", "cloud.bolt.rain")
        case 96, 99: ("雷阵雨伴冰雹", "cloud.bolt.rain")
        default: ("未知", "cloud")
        }
    }

    static func symbol(forText t: String) -> String {
        if t.contains("雷") { return "cloud.bolt.rain" }
        if t.contains("雪") { return "cloud.snow" }
        if t.contains("雨") { return "cloud.rain" }
        if t.contains("雾") || t.contains("霾") { return "cloud.fog" }
        if t.contains("阴") { return "cloud" }
        if t.contains("云") { return "cloud.sun" }
        if t.contains("晴") { return "sun.max" }
        return "cloud"
    }
}
