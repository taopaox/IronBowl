import Foundation
import IronBowlKit
import Testing
@testable import ZentaoLogPlugin

@Test func assignedWatcherEstablishesSilentBaselineAndDetectsNewOrReopenedItems() {
    let bug1 = ZentaoBug(id: 101, title: "登录白屏", severity: 2, priority: 1, status: "active", projectID: 1, productName: "App")
    let bug2 = ZentaoBug(id: 102, title: "列表闪退", severity: 1, priority: 1, status: "active", projectID: 1, productName: "App")
    let closedBug = ZentaoBug(id: 103, title: "历史已关", severity: 3, priority: 3, status: "closed", projectID: 1, productName: "App")

    let task1 = ZentaoTask(id: 201, name: "联调接口", projectID: 1, projectName: "饭碗", status: "doing", left: 4, consumed: 2)
    let task2 = ZentaoTask(id: 202, name: "重构模块", projectID: 1, projectName: "饭碗", status: "wait", left: 8, consumed: 0)

    // 1. 首次建立基线：静默记录，不产生新指派提醒
    let initial = ZentaoAssignedDiff.evaluate(
        openBugs: [bug1, closedBug],
        openTasks: [task1],
        knownBugIDs: nil,
        knownTaskIDs: nil,
        bugsOnly: false
    )
    #expect(initial.isInitialBaseline)
    #expect(!initial.hasNewItems)
    #expect(initial.nextKnownBugIDs == [101])
    #expect(initial.nextKnownTaskIDs == [201])

    // 2. 无新增时，不提醒
    let same = ZentaoAssignedDiff.evaluate(
        openBugs: [bug1],
        openTasks: [task1],
        knownBugIDs: initial.nextKnownBugIDs,
        knownTaskIDs: initial.nextKnownTaskIDs,
        bugsOnly: false
    )
    #expect(!same.hasNewItems)

    // 3. 新增 bug2 与 task2，应同时检出
    let added = ZentaoAssignedDiff.evaluate(
        openBugs: [bug1, bug2],
        openTasks: [task1, task2],
        knownBugIDs: initial.nextKnownBugIDs,
        knownTaskIDs: initial.nextKnownTaskIDs,
        bugsOnly: false
    )
    #expect(added.newBugs.map(\.id) == [102])
    #expect(added.newTasks.map(\.id) == [202])
    #expect(added.nextKnownBugIDs == [101, 102])
    #expect(added.nextKnownTaskIDs == [201, 202])

    // 4. 开启 bugsOnly 时，忽略新任务只报新 Bug
    let bugsOnlyResult = ZentaoAssignedDiff.evaluate(
        openBugs: [bug1, bug2],
        openTasks: [task1, task2],
        knownBugIDs: [101],
        knownTaskIDs: [201],
        bugsOnly: true
    )
    #expect(bugsOnlyResult.newBugs.map(\.id) == [102])
    #expect(bugsOnlyResult.newTasks.isEmpty)

    // 5. bug1 被解决后又重新激活（从基线移除后再出现），应能再次提醒
    let resolvedPass = ZentaoAssignedDiff.evaluate(
        openBugs: [bug2],
        openTasks: [task1, task2],
        knownBugIDs: added.nextKnownBugIDs,
        knownTaskIDs: added.nextKnownTaskIDs,
        bugsOnly: false
    )
    #expect(resolvedPass.nextKnownBugIDs == [102])

    let reopenedPass = ZentaoAssignedDiff.evaluate(
        openBugs: [bug1, bug2],
        openTasks: [task1, task2],
        knownBugIDs: resolvedPass.nextKnownBugIDs,
        knownTaskIDs: resolvedPass.nextKnownTaskIDs,
        bugsOnly: false
    )
    #expect(reopenedPass.newBugs.map(\.id) == [101])
}
