import Darwin
import Foundation
import Observation

/// 侧栏资源卡片的监控视角：系统整体 / 饭碗应用自身。
public enum ResourceScope: String, CaseIterable, Sendable, Equatable {
    case system
    case app

    public var title: String {
        switch self {
        case .system: "系统"
        case .app: "饭碗"
        }
    }
}

/// 饭碗关联进程分类。
public nonisolated enum AppResourceKind: String, Sendable, Equatable {
    case mainApp
    case webPage
    case childProcess

    public var label: String {
        switch self {
        case .mainApp: "主程序"
        case .webPage: "网页"
        case .childProcess: "子进程"
        }
    }
}

/// 由外部模块（如 WebSessionManager）提供的受跟踪进程描述。
public nonisolated struct TrackedProcessDescriptor: Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let detail: String?
    public let kind: AppResourceKind
    public let sessionID: String?
    public let isVisible: Bool
    public let neverSuspend: Bool

    public init(
        pid: pid_t,
        name: String,
        detail: String? = nil,
        kind: AppResourceKind,
        sessionID: String? = nil,
        isVisible: Bool = false,
        neverSuspend: Bool = false
    ) {
        self.pid = pid
        self.name = name
        self.detail = detail
        self.kind = kind
        self.sessionID = sessionID
        self.isVisible = isVisible
        self.neverSuspend = neverSuspend
    }
}

/// 饭碗单个关联进程的实时资源占用明细。
public nonisolated struct AppResourceItem: Identifiable, Sendable, Equatable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let detail: String?
    public let kind: AppResourceKind
    public let memoryBytes: UInt64
    public let cpuUsage: Double?
    public let sessionIDs: [String]
    public let isVisible: Bool
    public let neverSuspend: Bool

    public init(
        pid: pid_t,
        name: String,
        detail: String? = nil,
        kind: AppResourceKind,
        memoryBytes: UInt64,
        cpuUsage: Double?,
        sessionIDs: [String] = [],
        isVisible: Bool = false,
        neverSuspend: Bool = false
    ) {
        self.pid = pid
        self.name = name
        self.detail = detail
        self.kind = kind
        self.memoryBytes = memoryBytes
        self.cpuUsage = cpuUsage
        self.sessionIDs = sessionIDs
        self.isVisible = isVisible
        self.neverSuspend = neverSuspend
    }

    public var canSuspend: Bool {
        kind == .webPage && !sessionIDs.isEmpty && !isVisible
    }
}

/// 单次采样的系统与饭碗自身资源快照。
public nonisolated struct SystemResourceSnapshot: Sendable, Equatable {
    public var systemCPUUsage: Double?
    public var systemMemoryUsedBytes: UInt64
    public var systemMemoryTotalBytes: UInt64
    public var cpuCoreCount: Int

    public var appCPUUsage: Double?
    public var appMemoryBytes: UInt64
    public var appProcessCount: Int
    public var appItems: [AppResourceItem]

    public init(
        systemCPUUsage: Double? = nil,
        systemMemoryUsedBytes: UInt64 = 0,
        systemMemoryTotalBytes: UInt64 = 0,
        cpuCoreCount: Int = 1,
        appCPUUsage: Double? = nil,
        appMemoryBytes: UInt64 = 0,
        appProcessCount: Int = 0,
        appItems: [AppResourceItem] = []
    ) {
        self.systemCPUUsage = systemCPUUsage
        self.systemMemoryUsedBytes = systemMemoryUsedBytes
        self.systemMemoryTotalBytes = systemMemoryTotalBytes
        self.cpuCoreCount = cpuCoreCount
        self.appCPUUsage = appCPUUsage
        self.appMemoryBytes = appMemoryBytes
        self.appProcessCount = appProcessCount
        self.appItems = appItems
    }

    public var systemMemoryUsage: Double {
        guard systemMemoryTotalBytes > 0 else { return 0 }
        return min(1, max(0, Double(systemMemoryUsedBytes) / Double(systemMemoryTotalBytes)))
    }

    public var appMemoryUsage: Double {
        guard systemMemoryTotalBytes > 0 else { return 0 }
        return min(1, max(0, Double(appMemoryBytes) / Double(systemMemoryTotalBytes)))
    }

    public static let empty = SystemResourceSnapshot()
}

/// 资源占用格式化工具（内存采用 1024 进制，与 macOS 活动监视器一致）。
public nonisolated enum SystemResourceFormat {
    private static let kib: Double = 1_024
    private static let mib: Double = 1_024 * 1_024
    private static let gib: Double = 1_024 * 1_024 * 1_024

    public static func cpu(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return percent(ratio)
    }

    public static func percent(_ ratio: Double) -> String {
        let clamped = min(1, max(0, ratio))
        let pct = clamped * 100
        return pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
    }

    public static func memory(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= gib {
            let gb = value / gib
            return gb >= 10 ? String(format: "%.1f GB", gb) : String(format: "%.2f GB", gb)
        } else if value >= mib {
            return String(format: "%.0f MB", value / mib)
        } else {
            return String(format: "%.0f KB", value / kib)
        }
    }

    public static func memoryPair(used: UInt64, total: UInt64) -> String {
        guard total > 0 else { return memory(used) }
        let usedGB = Double(used) / gib
        let totalGB = Double(total) / gib
        let usedText = usedGB >= 100 ? String(format: "%.0f", usedGB) : String(format: "%.1f", usedGB)
        let totalText = abs(totalGB.rounded() - totalGB) < 0.05
            ? String(format: "%.0f GB", totalGB.rounded())
            : String(format: "%.1f GB", totalGB)
        return "\(usedText) / \(totalText)"
    }
}

nonisolated struct CPUTickSample: Sendable, Equatable {
    let active: UInt64
    let idle: UInt64
}

nonisolated struct MergedProcessMeta: Sendable, Equatable {
    let name: String
    let detail: String?
    let kind: AppResourceKind
    let sessionIDs: [String]
    let isVisible: Bool
    let neverSuspend: Bool
}

/// 定时采样整机与饭碗自身（含子进程及活跃 WKWebView 渲染进程）的 CPU 与内存占用。
@Observable
public final class SystemMonitor {
    public private(set) var snapshot: SystemResourceSnapshot = .empty

    @ObservationIgnored private let extraProcessesProvider: () -> [TrackedProcessDescriptor]
    @ObservationIgnored private let timebase: mach_timebase_info_data_t
    @ObservationIgnored private var previousCPUTicks: CPUTickSample?
    @ObservationIgnored private var previousProcessCPUNs: [pid_t: UInt64] = [:]
    @ObservationIgnored private var previousSampleWallNs: UInt64?

    public init(extraProcessesProvider: @escaping () -> [TrackedProcessDescriptor] = { [] }) {
        self.extraProcessesProvider = extraProcessesProvider
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.timebase = info
    }

    private struct SamplingState: Sendable {
        var previousCPUTicks: CPUTickSample?
        var previousProcessCPUNs: [pid_t: UInt64] = [:]
        var previousSampleWallNs: UInt64?
        var previousSystemCPUUsage: Double?
        var previousAppCPUUsage: Double?
    }

    private struct SampleOutput: Sendable {
        let snapshot: SystemResourceSnapshot
        let state: SamplingState
    }

    /// 采样一次当前系统与饭碗资源占用；首次采样建立 CPU 基线，第二次起输出 CPU 百分比。
    public func sampleNow() {
        let extra = extraProcessesProvider()
        let prevState = SamplingState(
            previousCPUTicks: previousCPUTicks,
            previousProcessCPUNs: previousProcessCPUNs,
            previousSampleWallNs: previousSampleWallNs,
            previousSystemCPUUsage: snapshot.systemCPUUsage,
            previousAppCPUUsage: snapshot.appCPUUsage
        )
        let output = Self.collectSample(extra: extra, state: prevState, timebase: timebase)
        applySampleOutput(output)
    }

    private func applySampleOutput(_ output: SampleOutput) {
        previousCPUTicks = output.state.previousCPUTicks
        previousProcessCPUNs = output.state.previousProcessCPUNs
        previousSampleWallNs = output.state.previousSampleWallNs
        if snapshot != output.snapshot {
            snapshot = output.snapshot
        }
    }

    /// 在视图生命周期内持续采样；内核采样置于后台线程执行，避免阻塞主线程切页与交互。
    public func run(interval: Duration = .seconds(2), initialDelay: Duration = .milliseconds(500)) async {
        await sampleAsync()
        try? await Task.sleep(for: initialDelay)
        guard !Task.isCancelled else { return }
        await sampleAsync()
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await sampleAsync()
        }
    }

    private func sampleAsync() async {
        let extra = extraProcessesProvider()
        let prevState = SamplingState(
            previousCPUTicks: previousCPUTicks,
            previousProcessCPUNs: previousProcessCPUNs,
            previousSampleWallNs: previousSampleWallNs,
            previousSystemCPUUsage: snapshot.systemCPUUsage,
            previousAppCPUUsage: snapshot.appCPUUsage
        )
        let tb = timebase
        let output = await Self.collectSampleInBackground(extra: extra, state: prevState, timebase: tb)
        guard !Task.isCancelled else { return }
        applySampleOutput(output)
    }

    @concurrent
    nonisolated private static func collectSampleInBackground(
        extra: [TrackedProcessDescriptor],
        state: SamplingState,
        timebase: mach_timebase_info_data_t
    ) async -> SampleOutput {
        collectSample(extra: extra, state: state, timebase: timebase)
    }

    nonisolated private static func collectSample(
        extra: [TrackedProcessDescriptor],
        state: SamplingState,
        timebase: mach_timebase_info_data_t
    ) -> SampleOutput {
        let wallNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let coreCount = max(1, ProcessInfo.processInfo.processorCount)

        let systemMemoryUsed = sampleSystemMemoryUsedBytes(totalBytes: totalBytes)
        let currentCPUTicks = sampleSystemCPUTicks()
        let systemCPUUsage: Double?
        if let prev = state.previousCPUTicks, let curr = currentCPUTicks {
            systemCPUUsage = computeSystemCPUUsage(previous: prev, current: curr)
        } else {
            systemCPUUsage = state.previousSystemCPUUsage
        }

        let selfPID = getpid()
        let childEntries = childPIDs(of: selfPID).map { ($0, processName(for: $0)) }
        let mergedMeta = mergeProcessDescriptors(
            selfPID: selfPID,
            extra: extra,
            childPIDs: childEntries
        )

        let elapsedWallNs: UInt64? = if let prevWallNs = state.previousSampleWallNs, wallNs > prevWallNs {
            wallNs - prevWallNs
        } else {
            nil
        }

        var appMemoryBytes: UInt64 = 0
        var currentProcessCPUNs: [pid_t: UInt64] = [:]
        var appItems: [AppResourceItem] = []

        for (pid, meta) in mergedMeta where pid > 0 {
            guard let usage = sampleProcessRusage(pid: pid, timebase: timebase) else { continue }
            appMemoryBytes &+= usage.footprintBytes
            currentProcessCPUNs[pid] = usage.cpuNs
            let itemCPU: Double? = if let elapsedWallNs {
                computeSingleProcessCPUUsage(
                    previousNs: state.previousProcessCPUNs[pid],
                    currentNs: usage.cpuNs,
                    elapsedWallNs: elapsedWallNs,
                    coreCount: coreCount
                )
            } else {
                nil
            }
            appItems.append(
                AppResourceItem(
                    pid: pid,
                    name: meta.name,
                    detail: meta.detail,
                    kind: meta.kind,
                    memoryBytes: usage.footprintBytes,
                    cpuUsage: itemCPU,
                    sessionIDs: meta.sessionIDs,
                    isVisible: meta.isVisible,
                    neverSuspend: meta.neverSuspend
                )
            )
        }

        appItems.sort { lhs, rhs in
            if lhs.memoryBytes != rhs.memoryBytes {
                return lhs.memoryBytes > rhs.memoryBytes
            }
            let lhsCPU = lhs.cpuUsage ?? -1
            let rhsCPU = rhs.cpuUsage ?? -1
            if lhsCPU != rhsCPU {
                return lhsCPU > rhsCPU
            }
            return lhs.pid < rhs.pid
        }

        let appCPUUsage: Double?
        if let elapsedWallNs {
            appCPUUsage = computeAppCPUUsage(
                previousCPUNs: state.previousProcessCPUNs,
                currentCPUNs: currentProcessCPUNs,
                elapsedWallNs: elapsedWallNs,
                coreCount: coreCount
            )
        } else {
            appCPUUsage = state.previousAppCPUUsage
        }

        let nextState = SamplingState(
            previousCPUTicks: currentCPUTicks ?? state.previousCPUTicks,
            previousProcessCPUNs: currentProcessCPUNs,
            previousSampleWallNs: wallNs,
            previousSystemCPUUsage: systemCPUUsage,
            previousAppCPUUsage: appCPUUsage
        )
        let nextSnapshot = SystemResourceSnapshot(
            systemCPUUsage: systemCPUUsage,
            systemMemoryUsedBytes: systemMemoryUsed,
            systemMemoryTotalBytes: totalBytes,
            cpuCoreCount: coreCount,
            appCPUUsage: appCPUUsage,
            appMemoryBytes: appMemoryBytes,
            appProcessCount: max(1, appItems.count),
            appItems: appItems
        )
        return SampleOutput(snapshot: nextSnapshot, state: nextState)
    }

    // MARK: - 可测试的纯计算逻辑

    nonisolated static func mergeProcessDescriptors(
        selfPID: pid_t,
        extra: [TrackedProcessDescriptor],
        childPIDs: [(pid: pid_t, name: String)]
    ) -> [pid_t: MergedProcessMeta] {
        var result: [pid_t: MergedProcessMeta] = [
            selfPID: MergedProcessMeta(
                name: "饭碗主程序",
                detail: "主进程与内置插件",
                kind: .mainApp,
                sessionIDs: [],
                isVisible: true,
                neverSuspend: true
            )
        ]

        var groupedExtra: [pid_t: [TrackedProcessDescriptor]] = [:]
        for item in extra where item.pid > 0 && item.pid != selfPID {
            groupedExtra[item.pid, default: []].append(item)
        }

        for (pid, group) in groupedExtra {
            var uniqueNames: [String] = []
            for entry in group where !uniqueNames.contains(entry.name) {
                uniqueNames.append(entry.name)
            }
            let primaryKind = group.first?.kind ?? .webPage
            let sessionIDs = group.compactMap(\.sessionID)
            let isVisible = group.contains(where: \.isVisible)
            let neverSuspend = group.allSatisfy(\.neverSuspend)

            let name: String
            let detail: String?
            if uniqueNames.count > 1 {
                name = "\(uniqueNames[0]) 等 \(uniqueNames.count) 个网页"
                detail = "共享进程：" + uniqueNames.joined(separator: "、")
            } else {
                name = uniqueNames.first ?? "网页进程"
                detail = group.compactMap(\.detail).first(where: { !$0.isEmpty })
            }

            result[pid] = MergedProcessMeta(
                name: name,
                detail: detail,
                kind: primaryKind,
                sessionIDs: sessionIDs,
                isVisible: isVisible,
                neverSuspend: neverSuspend
            )
        }

        for (childPID, childName) in childPIDs where childPID > 0 && result[childPID] == nil {
            result[childPID] = MergedProcessMeta(
                name: childName,
                detail: "后台子进程",
                kind: .childProcess,
                sessionIDs: [],
                isVisible: false,
                neverSuspend: true
            )
        }

        return result
    }

    nonisolated static func computeSystemCPUUsage(previous: CPUTickSample, current: CPUTickSample) -> Double? {
        let activeDelta = current.active &- previous.active
        let idleDelta = current.idle &- previous.idle
        let totalDelta = activeDelta &+ idleDelta
        guard totalDelta > 0 else { return nil }
        return min(1, max(0, Double(activeDelta) / Double(totalDelta)))
    }

    nonisolated static func computeSingleProcessCPUUsage(
        previousNs: UInt64?,
        currentNs: UInt64,
        elapsedWallNs: UInt64,
        coreCount: Int
    ) -> Double? {
        guard let previousNs, elapsedWallNs > 0, coreCount > 0, currentNs >= previousNs else {
            return nil
        }
        let capacityNs = Double(elapsedWallNs) * Double(coreCount)
        guard capacityNs > 0 else { return nil }
        return min(1, max(0, Double(currentNs - previousNs) / capacityNs))
    }

    nonisolated static func computeAppCPUUsage(
        previousCPUNs: [pid_t: UInt64],
        currentCPUNs: [pid_t: UInt64],
        elapsedWallNs: UInt64,
        coreCount: Int
    ) -> Double? {
        guard elapsedWallNs > 0, coreCount > 0 else { return nil }
        var cpuDeltaNs: UInt64 = 0
        for (pid, currNs) in currentCPUNs {
            if let prevNs = previousCPUNs[pid], currNs >= prevNs {
                cpuDeltaNs &+= (currNs - prevNs)
            }
        }
        let capacityNs = Double(elapsedWallNs) * Double(coreCount)
        guard capacityNs > 0 else { return nil }
        return min(1, max(0, Double(cpuDeltaNs) / capacityNs))
    }

    nonisolated static func computeSystemMemoryUsedBytes(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        pageSize: UInt64,
        totalBytes: UInt64
    ) -> UInt64 {
        let appPages = internalPages >= purgeablePages ? (internalPages - purgeablePages) : 0
        let usedPages = appPages &+ wiredPages &+ compressedPages
        let usedBytes = usedPages.multipliedReportingOverflow(by: pageSize).partialValue
        return totalBytes > 0 ? min(totalBytes, usedBytes) : usedBytes
    }

    nonisolated static func machTicksToNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        let n = UInt64(numer)
        let d = UInt64(max(1, denom))
        return (ticks / d) * n + ((ticks % d) * n) / d
    }

    // MARK: - Darwin / Mach 采样

    nonisolated private static func sampleSystemMemoryUsedBytes(totalBytes: UInt64) -> UInt64 {
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return 0 }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        return Self.computeSystemMemoryUsedBytes(
            internalPages: UInt64(vmStats.internal_page_count),
            purgeablePages: UInt64(vmStats.purgeable_count),
            wiredPages: UInt64(vmStats.wire_count),
            compressedPages: UInt64(vmStats.compressor_page_count),
            pageSize: UInt64(pageSize),
            totalBytes: totalBytes
        )
    }

    nonisolated private static func sampleSystemCPUTicks() -> CPUTickSample? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &cpuInfoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return nil }
        defer {
            let byteCount = Int(cpuInfoCount) * MemoryLayout<integer_t>.stride
            vm_deallocate(task_self_trap(), vm_address_t(bitPattern: info), vm_size_t(byteCount))
        }

        let stride = Int(CPU_STATE_MAX)
        var active: UInt64 = 0
        var idle: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            guard base + Int(CPU_STATE_NICE) < Int(cpuInfoCount) else { break }
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let cpuIdle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            active &+= user &+ system &+ nice
            idle &+= cpuIdle
        }
        return CPUTickSample(active: active, idle: idle)
    }

    nonisolated private static func sampleProcessRusage(
        pid: pid_t,
        timebase: mach_timebase_info_data_t
    ) -> (footprintBytes: UInt64, cpuNs: UInt64)? {
        var rusage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        guard result == 0 else { return nil }
        let totalTicks = rusage.ri_user_time &+ rusage.ri_system_time
        let cpuNs = Self.machTicksToNanoseconds(totalTicks, numer: timebase.numer, denom: timebase.denom)
        return (rusage.ri_phys_footprint, cpuNs)
    }

    nonisolated private static func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let len = buffer.withUnsafeMutableBytes { buf in
            proc_name(pid, buf.baseAddress, UInt32(buf.count))
        }
        guard len > 0 else { return "子进程 #\(pid)" }
        buffer[buffer.count - 1] = 0
        let decoded = buffer.withUnsafeBufferPointer { ptr in
            String(decoding: ptr.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "子进程 #\(pid)" : trimmed
    }

    nonisolated private static func childPIDs(of parentPID: pid_t) -> [pid_t] {
        let initialBytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parentPID), nil, 0)
        guard initialBytes > 0 else { return [] }
        let capacity = Int(initialBytes) / MemoryLayout<pid_t>.stride + 8
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytesReturned = pids.withUnsafeMutableBytes { buf in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parentPID), buf.baseAddress, Int32(buf.count))
        }
        guard bytesReturned > 0 else { return [] }
        let count = Int(bytesReturned) / MemoryLayout<pid_t>.stride
        return pids.prefix(count).filter { $0 > 0 }
    }
}
