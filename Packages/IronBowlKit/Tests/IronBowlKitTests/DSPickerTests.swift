import Foundation
import Testing
@testable import IronBowlKit

@Test func pickerOptionStoresFields() {
    let opt = DSPickerOption("keep", title: "熄屏后保持唤醒", subtitle: "屏幕会正常熄灭，后台任务照常执行。", triggerTitle: "保持唤醒")
    #expect(opt.id == "keep")
    #expect(opt.value == "keep")
    #expect(opt.title == "熄屏后保持唤醒")
    #expect(opt.subtitle == "屏幕会正常熄灭，后台任务照常执行。")
    #expect(opt.triggerTitle == "保持唤醒")

    let simple = DSPickerOption(42, title: "42")
    #expect(simple.subtitle == nil)
    #expect(simple.triggerTitle == nil)
}

@Test func aiProviderMetadataPresent() {
    for kind in AIProviderKind.allCases {
        #expect(!kind.displayName.isEmpty)
        #expect(!kind.detail.isEmpty)
        for effort in kind.effortOptions {
            #expect(!AIProviderKind.effortTitle(effort).isEmpty)
            #expect(!AIProviderKind.effortDetail(effort).isEmpty)
        }
    }
    #expect(AIProviderKind.effortTitle("") == "默认")
}

@Test func holidayOptionsMetadataPresent() {
    for source in HolidaySource.allCases {
        #expect(!source.displayName.isEmpty)
        #expect(!source.detail.isEmpty)
    }
    for freq in HolidayUpdateFrequency.allCases {
        #expect(!freq.displayName.isEmpty)
        #expect(!freq.detail.isEmpty)
    }
}
