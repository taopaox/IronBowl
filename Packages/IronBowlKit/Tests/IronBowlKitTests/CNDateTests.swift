import Foundation
import Testing
@testable import IronBowlKit

@Test func chineseDateFormats() {
    var c = DateComponents()
    c.year = 2026; c.month = 11; c.day = 25; c.hour = 14; c.minute = 5
    let d = Calendar(identifier: .gregorian).date(from: c)!
    #expect(CN.monthDay(d) == "11月25日")
    #expect(CN.weekdayShort(d) == "周三")
    #expect(CN.weekday(d) == "星期三")
    #expect(CN.time(d) == "14:05")
    #expect(CN.full(d) == "2026年11月25日 星期三")
    #expect(CN.slash(d) == "11/25")
}
