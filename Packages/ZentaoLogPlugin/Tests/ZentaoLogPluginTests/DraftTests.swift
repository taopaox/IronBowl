import Foundation
import Testing
@testable import ZentaoLogPlugin

@Test func allocateKeepsTotalInHalfHours() {
    let r = DraftGenerator.allocate(total: 8, weights: [10, 1, 3])
    #expect(r.reduce(0, +) == 8)
    #expect(r.allSatisfy { ($0 * 2).rounded() == $0 * 2 && $0 >= 0.5 })
    #expect(r[0] > r[2] && r[2] >= r[1])
}

@Test func allocateZeroBudget() {
    #expect(DraftGenerator.allocate(total: 0, weights: [1, 2]) == [0, 0])
}

@Test func cleanSubjectStripsConventionalPrefix() {
    #expect(DraftGenerator.cleanSubject("fix(driver): 取消预约弹窗不再被遮挡") == "取消预约弹窗不再被遮挡")
    #expect(DraftGenerator.cleanSubject("♻️(refactor): 拆分 Windows 部署") == "拆分 Windows 部署")
    #expect(DraftGenerator.cleanSubject("add") == "")
    #expect(DraftGenerator.cleanSubject("承包商: 修复照片回显") == "修复照片回显")
}

@Test func parsesGitLog() {
    let text = "\u{1e}abc\u{1f}2026-11-25T10:00:00+08:00\u{1f}feat: 新功能\n\n10\t2\tsrc/a.vue\n-\t-\timg.png\n\u{1e}def\u{1f}2026-11-25T11:00:00+08:00\u{1f}add\n"
    let commits = GitScanner.parseLog(text)
    #expect(commits.count == 2)
    #expect(commits[0].files.count == 2 && commits[0].lines == 12)
    #expect(commits[1].subject == "add" && commits[1].files.isEmpty)
}

@Test func mergeWorkRenumbers() {
    #expect(DraftGenerator.mergeWork("1. A\n2. B", "1. B\n2. C") == "1. A\n2. B\n3. C")
}
