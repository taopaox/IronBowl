import Foundation
import Testing
@testable import IronBowlKit

@Test func resourceFormattingMatchesActivityMonitorBinaryUnits() {
    #expect(SystemResourceFormat.cpu(nil) == "—")
    #expect(SystemResourceFormat.cpu(0.043) == "4.3%")
    #expect(SystemResourceFormat.cpu(0.126) == "13%")
    #expect(SystemResourceFormat.cpu(1.25) == "100%")
    #expect(SystemResourceFormat.cpu(-0.2) == "0.0%")

    #expect(SystemResourceFormat.memory(512 * 1_024) == "512 KB")
    #expect(SystemResourceFormat.memory(256 * 1_024 * 1_024) == "256 MB")
    #expect(SystemResourceFormat.memory(2_500 * 1_024 * 1_024) == "2.44 GB")
    #expect(SystemResourceFormat.memory(12 * 1_024 * 1_024 * 1_024) == "12.0 GB")

    let used: UInt64 = 11_200 * 1_024 * 1_024
    let total: UInt64 = 16 * 1_024 * 1_024 * 1_024
    #expect(SystemResourceFormat.memoryPair(used: used, total: total) == "10.9 / 16 GB")
}

@Test func systemCPUCalculationHandlesDeltaAndOverflow() {
    let prev = CPUTickSample(active: 1_000, idle: 3_000)
    let curr = CPUTickSample(active: 1_250, idle: 3_750)
    let ratio = SystemMonitor.computeSystemCPUUsage(previous: prev, current: curr)
    #expect(ratio == 0.25)

    // 同一采样点无增量时返回 nil
    #expect(SystemMonitor.computeSystemCPUUsage(previous: curr, current: curr) == nil)
}

@Test func appCPUCalculationSumsOnlyMatchedPIDsAndNormalizesByCoreCount() {
    let prev: [pid_t: UInt64] = [100: 1_000_000_000, 200: 500_000_000, 300: 900_000_000]
    let curr: [pid_t: UInt64] = [100: 1_500_000_000, 200: 1_500_000_000, 400: 2_000_000_000]
    // PID 100 (+0.5s) + PID 200 (+1.0s) = 1.5s; PID 300 exited, PID 400 new -> ignored
    let ratio = SystemMonitor.computeAppCPUUsage(
        previousCPUNs: prev,
        currentCPUNs: curr,
        elapsedWallNs: 1_000_000_000,
        coreCount: 10
    )
    #expect(ratio != nil)
    #expect(abs((ratio ?? 0) - 0.15) < 0.0001)
}

@Test func systemMemoryFormulaMatchesActivityMonitor() {
    let pageSize: UInt64 = 16_384
    let total: UInt64 = 16 * 1_024 * 1_024 * 1_024
    // (internal 200_000 - purgeable 50_000) + wired 100_000 + compressed 50_000 = 300_000 pages
    let used = SystemMonitor.computeSystemMemoryUsedBytes(
        internalPages: 200_000,
        purgeablePages: 50_000,
        wiredPages: 100_000,
        compressedPages: 50_000,
        pageSize: pageSize,
        totalBytes: total
    )
    #expect(used == 300_000 * pageSize)

    // 即使 page 计算大于物理上限，也限制在物理总内存内
    let clamped = SystemMonitor.computeSystemMemoryUsedBytes(
        internalPages: 2_000_000,
        purgeablePages: 0,
        wiredPages: 500_000,
        compressedPages: 500_000,
        pageSize: pageSize,
        totalBytes: total
    )
    #expect(clamped == total)
}

@Test func machTimebaseConversionAvoidsOverflow() {
    let ns = SystemMonitor.machTicksToNanoseconds(1_000_000, numer: 125, denom: 3)
    #expect(ns == 41_666_666)
}

@Test func mergeProcessDescriptorsCombinesSharedWebPIDAndRespectsPriority() {
    let extra = [
        TrackedProcessDescriptor(
            pid: 200,
            name: "飞书文档",
            detail: "feishu.cn",
            kind: .webPage,
            sessionID: "feishu.home",
            isVisible: false,
            neverSuspend: false
        ),
        TrackedProcessDescriptor(
            pid: 200,
            name: "ChatGPT",
            detail: "chatgpt.com",
            kind: .webPage,
            sessionID: "aiweb.chatgpt",
            isVisible: true,
            neverSuspend: false
        ),
        TrackedProcessDescriptor(
            pid: 300,
            name: "Claude",
            detail: "claude.ai",
            kind: .webPage,
            sessionID: "aiweb.claude",
            isVisible: false,
            neverSuspend: true
        ),
        // 与主进程同 PID 的异常项应被忽略，主程序优先
        TrackedProcessDescriptor(
            pid: 100,
            name: "Ignored",
            kind: .webPage,
            sessionID: "bad"
        ),
    ]
    let children: [(pid: pid_t, name: String)] = [
        (pid: 200, name: "com.apple.WebKit.WebContent"), // 已被 extra 认领
        (pid: 400, name: "git")
    ]

    let merged = SystemMonitor.mergeProcessDescriptors(selfPID: 100, extra: extra, childPIDs: children)
    #expect(merged.count == 4)
    #expect(merged[100]?.kind == .mainApp)
    #expect(merged[100]?.name == "饭碗主程序")

    let shared = merged[200]
    #expect(shared?.name == "飞书文档 等 2 个网页")
    #expect(shared?.detail == "共享进程：飞书文档、ChatGPT")
    #expect(shared?.sessionIDs == ["feishu.home", "aiweb.chatgpt"])
    #expect(shared?.isVisible == true)
    #expect(shared?.neverSuspend == false)

    #expect(merged[300]?.name == "Claude")
    #expect(merged[300]?.detail == "claude.ai")
    #expect(merged[300]?.neverSuspend == true)

    #expect(merged[400]?.kind == .childProcess)
    #expect(merged[400]?.name == "git")
}

@Test func singleProcessCPUAndCanSuspendBehavior() {
    #expect(SystemMonitor.computeSingleProcessCPUUsage(
        previousNs: nil,
        currentNs: 500_000_000,
        elapsedWallNs: 1_000_000_000,
        coreCount: 8
    ) == nil)

    let cpu = SystemMonitor.computeSingleProcessCPUUsage(
        previousNs: 1_000_000_000,
        currentNs: 2_600_000_000,
        elapsedWallNs: 1_000_000_000,
        coreCount: 8
    )
    #expect(cpu != nil)
    #expect(abs((cpu ?? 0) - 0.2) < 0.0001)

    let backgroundWeb = AppResourceItem(
        pid: 201,
        name: "DeepSeek",
        kind: .webPage,
        memoryBytes: 120 * 1_024 * 1_024,
        cpuUsage: 0.02,
        sessionIDs: ["aiweb.deepseek"],
        isVisible: false
    )
    #expect(backgroundWeb.canSuspend)

    let visibleWeb = AppResourceItem(
        pid: 202,
        name: "飞书",
        kind: .webPage,
        memoryBytes: 180 * 1_024 * 1_024,
        cpuUsage: 0.05,
        sessionIDs: ["feishu.home"],
        isVisible: true
    )
    #expect(!visibleWeb.canSuspend)

    let mainItem = AppResourceItem(
        pid: 100,
        name: "饭碗主程序",
        kind: .mainApp,
        memoryBytes: 80 * 1_024 * 1_024,
        cpuUsage: 0.01
    )
    #expect(!mainItem.canSuspend)
}

@MainActor @Test func liveSampleProducesPlausibleMetrics() async {
    let monitor = SystemMonitor()
    monitor.sampleNow()
    let first = monitor.snapshot
    #expect(first.systemMemoryTotalBytes > 0)
    #expect(first.systemMemoryUsedBytes > 0)
    #expect(first.systemMemoryUsedBytes <= first.systemMemoryTotalBytes)
    #expect(first.cpuCoreCount >= 1)
    #expect(first.appMemoryBytes > 0)
    #expect(first.appProcessCount >= 1)
    #expect(first.systemCPUUsage == nil)
    #expect(first.appItems.contains { $0.kind == .mainApp && $0.name == "饭碗主程序" })
    #expect(first.appItems.reduce(UInt64(0)) { $0 + $1.memoryBytes } == first.appMemoryBytes)

    try? await Task.sleep(for: .milliseconds(100))
    monitor.sampleNow()
    let second = monitor.snapshot
    #expect(second.systemCPUUsage != nil)
    #expect((second.systemCPUUsage ?? -1) >= 0 && (second.systemCPUUsage ?? 2) <= 1)
    #expect(second.appCPUUsage != nil)
    #expect((second.appCPUUsage ?? -1) >= 0 && (second.appCPUUsage ?? 2) <= 1)
    #expect(second.appItems.contains { $0.kind == .mainApp && $0.cpuUsage != nil })
}
