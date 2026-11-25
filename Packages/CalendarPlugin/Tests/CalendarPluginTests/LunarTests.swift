import Foundation
import Testing
@testable import CalendarPlugin

private func day(_ s: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f.date(from: s)!
}

@Test func lunarMatchesBaidu() {
    // 百度日历：2026-11-25 = 十月十七，丙午年 马
    let l = Lunar.lunar(day("2026-11-25"))
    #expect(l.text == "十月十七")
    #expect(l.ganzhiYear == "丙午年")
    #expect(l.zodiac == "马")
    #expect(Lunar.lunar(day("2026-10-29")).text == "九月二十")
}

@Test func solarTermsMatchBaidu() {
    #expect(Lunar.solarTerm(day("2026-11-07")) == "立冬")
    #expect(Lunar.solarTerm(day("2026-11-22")) == "小雪")
    #expect(Lunar.solarTerm(day("2026-10-08")) == "寒露")
    #expect(Lunar.solarTerm(day("2026-10-23")) == "霜降")
    #expect(Lunar.solarTerm(day("2026-11-08")) == nil)
}

@Test func festivals() {
    #expect(Lunar.festival(day("2026-10-01")) == "国庆节")
    #expect(Lunar.festival(day("2026-11-26")) == "感恩节")
    #expect(Lunar.festival(day("2026-10-18")) == "重阳节")   // 百度：10/18 重阳节
    #expect(Lunar.festival(day("2026-11-09")) == "寒衣节")   // 百度：11/9 寒衣节
    #expect(Lunar.festival(day("2026-11-23")) == "下元节")   // 百度：11/23 下元节
    #expect(Lunar.festival(day("2027-02-05")) == "除夕")
    #expect(Lunar.festival(day("2027-02-06")) == "春节")
}

@Test func cellLabelPriority() {
    #expect(Lunar.cellLabel(day("2026-11-07")).text == "立冬")
    #expect(Lunar.cellLabel(day("2026-11-10")).text == "初二")
    #expect(Lunar.cellLabel(day("2026-10-10")).text == "初一")   // 百度：10/10 显示"初一"
}

/// 2026 年全部 24 节气（国家授时中心公布的日期）。
@Test func allSolarTerms2026() {
    let expected = ["01-05", "01-20", "02-04", "02-18", "03-05", "03-20", "04-05", "04-20", "05-05", "05-21", "06-05", "06-21",
                    "07-07", "07-23", "08-07", "08-23", "09-07", "09-23", "10-08", "10-23", "11-07", "11-22", "12-07", "12-22"]
    for (i, md) in expected.enumerated() {
        #expect(Lunar.solarTermDay(year: 2026, index: i) == "2026-\(md)", "\(Lunar.solarTermNames[i])")
    }
}

/// 2025、2027 年抽查。
@Test func solarTermsOtherYears() {
    #expect(Lunar.solarTermDay(year: 2025, index: 11) == "2025-06-21") // 夏至
    #expect(Lunar.solarTermDay(year: 2025, index: 23) == "2025-12-21") // 冬至
    #expect(Lunar.solarTermDay(year: 2027, index: 2) == "2027-02-04")  // 立春
    #expect(Lunar.solarTermDay(year: 2027, index: 6) == "2027-04-05")  // 清明
}
