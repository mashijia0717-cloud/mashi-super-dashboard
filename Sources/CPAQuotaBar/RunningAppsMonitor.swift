import AppKit
import Darwin
import Foundation

struct RunningAppsMonitor: Sendable {
    typealias ProcessInfoProvider = @Sendable (pid_t) -> proc_bsdinfo?
    typealias ResidentMemoryProvider = @Sendable (pid_t) -> UInt64?
    typealias CPUTimeProvider = @Sendable (pid_t) -> UInt64?
    typealias ProcessExistenceProvider = @Sendable (pid_t) -> Bool?

    private let processInfoProvider: ProcessInfoProvider
    private let residentMemoryProvider: ResidentMemoryProvider
    private let cpuTimeProvider: CPUTimeProvider
    private let processExistenceProvider: ProcessExistenceProvider
    private let usesDefaultProviders: Bool
    private let samplingState = RunningAppSamplingState()
    private let samplingLock = NSLock()

    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(numer: 1, denom: 1)
        mach_timebase_info(&info)
        if info.denom == 0 { info = mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }()

    init(
        processInfoProvider: ProcessInfoProvider? = nil,
        residentMemoryProvider: ResidentMemoryProvider? = nil,
        cpuTimeProvider: CPUTimeProvider? = nil,
        processExistenceProvider: ProcessExistenceProvider? = nil
    ) {
        self.usesDefaultProviders =
            processInfoProvider == nil && residentMemoryProvider == nil && cpuTimeProvider == nil
        self.processInfoProvider = processInfoProvider ?? Self.readProcessInfo
        self.residentMemoryProvider = residentMemoryProvider ?? Self.readResidentMemory
        self.cpuTimeProvider = cpuTimeProvider ?? Self.readCPUTime
        self.processExistenceProvider = processExistenceProvider ?? Self.processExists
    }

    @MainActor
    func candidates() -> [RunningAppCandidate] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let processIdentifiers = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        return processIdentifiers.compactMap { processIdentifier in
            captureCandidate(processIdentifier: processIdentifier) { identity in
                guard let application = NSRunningApplication(processIdentifier: processIdentifier),
                      !application.isTerminated else { return nil }
                let candidate = RunningAppCandidate(
                    identity: identity,
                    localizedName: application.localizedName,
                    bundleIdentifier: application.bundleIdentifier,
                    executableURL: application.executableURL,
                    isRegular: application.activationPolicy == .regular,
                    isCurrentApplication: processIdentifier == currentPID,
                    isActive: application.isActive
                )
                return application.isTerminated ? nil : candidate
            }
        }
    }

    func captureCandidate(
        processIdentifier: pid_t,
        metadata: (RunningAppIdentity) -> RunningAppCandidate?
    ) -> RunningAppCandidate? {
        guard let identity = readIdentity(processIdentifier: processIdentifier),
              let candidate = metadata(identity),
              candidate.identity == identity,
              readIdentity(processIdentifier: processIdentifier) == identity else { return nil }
        return candidate
    }

    private func readIdentity(processIdentifier: pid_t) -> RunningAppIdentity? {
        guard processIdentifier > 0,
              let info = processInfoProvider(processIdentifier),
              info.pbi_status != SZOMB else { return nil }
        return Self.identity(processIdentifier: processIdentifier, info: info)
    }

    func sample(_ candidates: [RunningAppCandidate], sampledAt: Date = Date()) -> [RunningApp] {
        samplingLock.lock()
        defer { samplingLock.unlock() }
        let now = sampledAt
        let eligibleCandidates = RunningAppHelpers.eligibleCandidates(candidates)
        let apps = eligibleCandidates.compactMap { candidate -> RunningApp? in
            guard readIdentity(processIdentifier: candidate.processIdentifier) == candidate.identity else { return nil }
            let residentMemoryBytes: UInt64
            let rawCPUNanoseconds: UInt64?
            let memoryMeasurement: RunningAppMemoryMeasurement

            if usesDefaultProviders {
                guard let taskSnapshot = Self.readTaskSnapshot(processIdentifier: candidate.processIdentifier) else {
                    return nil
                }
                if let footprint = Self.readPhysicalFootprint(processIdentifier: candidate.processIdentifier) {
                    residentMemoryBytes = footprint
                    memoryMeasurement = .physicalFootprint
                } else {
                    residentMemoryBytes = taskSnapshot.residentBytes
                    memoryMeasurement = .resident
                }
                rawCPUNanoseconds = taskSnapshot.cpuTimeNanoseconds
            } else {
                guard let sampledMemory = residentMemoryProvider(candidate.processIdentifier) else { return nil }
                residentMemoryBytes = sampledMemory
                memoryMeasurement = .physicalFootprint
                rawCPUNanoseconds = cpuTimeProvider(candidate.processIdentifier)
            }
            guard readIdentity(processIdentifier: candidate.processIdentifier) == candidate.identity else { return nil }
            let finalIdentity = candidate.identity

            let cpuUsage = rawCPUNanoseconds.flatMap {
                samplingState.usage(
                    identity: finalIdentity,
                    cpuTimeNanoseconds: $0,
                    sampledAt: now
                )
            }
            let memoryDelta = samplingState.recordMemoryAndDelta(
                identity: finalIdentity,
                memoryBytes: residentMemoryBytes,
                measurement: memoryMeasurement,
                sampledAt: now
            )
            let startDate = Date(
                timeIntervalSince1970: TimeInterval(finalIdentity.startTimeSeconds)
                    + TimeInterval(finalIdentity.startTimeMicroseconds) / 1_000_000
            )
            return RunningApp(
                identity: finalIdentity,
                localizedName: candidate.localizedName ?? candidate.executableURL?.lastPathComponent ?? "未知应用",
                bundleIdentifier: candidate.bundleIdentifier,
                executableURL: candidate.executableURL,
                residentMemoryBytes: residentMemoryBytes,
                cpuUsage: cpuUsage,
                runningDuration: max(0, now.timeIntervalSince(startDate)),
                memoryDeltaBytes: memoryDelta.baseline,
                recentMemoryDeltaBytes: memoryDelta.recent,
                memorySampleInterval: memoryDelta.interval,
                memoryMeasurement: memoryMeasurement,
                isActive: candidate.isActive
            )
        }
        samplingState.prune(
            keeping: Set(eligibleCandidates.map(\.processIdentifier)),
            observedIdentities: Set(apps.map(\.identity))
        )
        return RunningAppHelpers.sortedByResidentMemory(apps)
    }

    func isIdentityRunning(_ identity: RunningAppIdentity) -> Bool? {
        guard identity.processIdentifier > 0 else { return nil }
        if let info = processInfoProvider(identity.processIdentifier) {
            let observed = Self.identity(processIdentifier: identity.processIdentifier, info: info)
            return info.pbi_status != SZOMB && observed == identity
        }
        return processExistenceProvider(identity.processIdentifier) == false ? false : nil
    }

    private static func processExists(_ processIdentifier: pid_t) -> Bool? {
        guard processIdentifier > 0 else { return nil }
        if kill(processIdentifier, 0) == 0 { return true }
        let error = errno
        if error == ESRCH { return false }
        if error == EPERM { return true }
        return nil
    }

    @MainActor
    func terminateGracefully(_ identity: RunningAppIdentity) -> RunningAppTerminationResult {
        requestTermination(identity) {
            guard let application = NSRunningApplication(processIdentifier: identity.processIdentifier),
                  !application.isTerminated else { return nil }
            return { application.terminate() }
        }
    }

    /// Revalidates process start time immediately before requesting force termination.
    @MainActor
    func forceTerminate(_ identity: RunningAppIdentity) -> RunningAppTerminationResult {
        requestTermination(identity) {
            guard let application = NSRunningApplication(processIdentifier: identity.processIdentifier),
                  !application.isTerminated else { return nil }
            return { application.forceTerminate() }
        }
    }

    @MainActor
    func requestTermination(
        _ identity: RunningAppIdentity,
        prepareRequest: () -> (@MainActor () -> Bool)?
    ) -> RunningAppTerminationResult {
        guard let initialIdentity = readIdentity(processIdentifier: identity.processIdentifier) else {
            return .applicationNotRunning
        }
        guard initialIdentity == identity else { return .identityChanged }
        guard let request = prepareRequest(),
              let finalIdentity = readIdentity(processIdentifier: identity.processIdentifier) else {
            return .applicationNotRunning
        }
        guard finalIdentity == identity else {
            return .identityChanged
        }
        return request() ? .terminated : .requestRejected
    }

    static func identity(processIdentifier: pid_t, info: proc_bsdinfo) -> RunningAppIdentity {
        RunningAppIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    static func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let numer = UInt64(machTimebase.numer)
        let denom = UInt64(max(machTimebase.denom, 1))
        if numer == denom { return ticks }
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        guard high < denom else { return UInt64.max }
        return denom.dividingFullWidth((high: high, low: low)).quotient
    }

    private static func readTaskSnapshot(processIdentifier: pid_t) -> (residentBytes: UInt64, cpuTimeNanoseconds: UInt64)? {
        var taskInfo = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride
        let bytesRead = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTASKINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard bytesRead == Int32(expectedSize) else { return nil }
        let totalTicks = taskInfo.pti_total_user &+ taskInfo.pti_total_system
        return (taskInfo.pti_resident_size, ticksToNanoseconds(totalTicks))
    }

    /// 与 macOS 活动监视器一致的真实物理内存足迹（扣除只读共享动态库，计入该进程独占压缩页）。
    static func readPhysicalFootprint(processIdentifier: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0, usage.ri_phys_footprint > 0 else { return nil }
        return usage.ri_phys_footprint
    }

    static func readResidentMemory(processIdentifier: pid_t) -> UInt64? {
        readPhysicalFootprint(processIdentifier: processIdentifier)
            ?? readTaskSnapshot(processIdentifier: processIdentifier)?.residentBytes
    }

    static func readCPUTime(processIdentifier: pid_t) -> UInt64? {
        readTaskSnapshot(processIdentifier: processIdentifier)?.cpuTimeNanoseconds
    }

    static func readProcessInfo(processIdentifier: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard bytesRead == Int32(expectedSize) else { return nil }
        return info
    }
}

final class RunningAppSamplingState: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [
        RunningAppIdentity: (cpuTimeNanoseconds: UInt64, sampledAt: Date)
    ] = [:]
    private var memorySamples: [
        RunningAppIdentity: (baseline: UInt64, previous: UInt64, measurement: RunningAppMemoryMeasurement, sampledAt: Date)
    ] = [:]

    func usage(
        identity: RunningAppIdentity,
        cpuTimeNanoseconds: UInt64,
        sampledAt: Date
    ) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let old = previous[identity]
        if let old, sampledAt <= old.sampledAt { return nil }
        previous[identity] = (cpuTimeNanoseconds, sampledAt)
        guard let old,
              cpuTimeNanoseconds >= old.cpuTimeNanoseconds else { return nil }
        let elapsed = sampledAt.timeIntervalSince(old.sampledAt)
        guard elapsed > 0 else { return nil }
        let cpuSeconds = Double(cpuTimeNanoseconds - old.cpuTimeNanoseconds) / 1_000_000_000
        let maxCores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return min(max(cpuSeconds / elapsed, 0), maxCores)
    }

    func recordMemoryAndDelta(
        identity: RunningAppIdentity,
        memoryBytes: UInt64,
        measurement: RunningAppMemoryMeasurement,
        sampledAt: Date
    ) -> (baseline: Int64, recent: Int64?, interval: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        let old = memorySamples[identity]
        if let old, sampledAt <= old.sampledAt { return (0, nil, nil) }
        guard let old, old.measurement == measurement else {
            memorySamples[identity] = (memoryBytes, memoryBytes, measurement, sampledAt)
            return (0, nil, nil)
        }
        memorySamples[identity] = (old.baseline, memoryBytes, measurement, sampledAt)
        return (
            RunningAppHelpers.memoryChange(from: old.baseline, to: memoryBytes),
            RunningAppHelpers.memoryChange(from: old.previous, to: memoryBytes),
            sampledAt.timeIntervalSince(old.sampledAt)
        )
    }

    func prune(keeping activeProcessIdentifiers: Set<pid_t>, observedIdentities: Set<RunningAppIdentity>) {
        lock.lock()
        defer { lock.unlock() }
        let observedProcessIdentifiers = Set(observedIdentities.map(\.processIdentifier))
        let shouldKeep: (RunningAppIdentity) -> Bool = { identity in
            activeProcessIdentifiers.contains(identity.processIdentifier)
                && (!observedProcessIdentifiers.contains(identity.processIdentifier) || observedIdentities.contains(identity))
        }
        previous = previous.filter { shouldKeep($0.key) }
        memorySamples = memorySamples.filter { shouldKeep($0.key) }
    }
}

/// 按需扫描本机 TCP LISTEN 端口（仅在用户打开“端口”子页时调用，零后台开销）。
enum ListeningPortScanner {
    static func scan(shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }) -> [ListeningPortItem] {
        guard shouldContinue(), FileManager.default.isExecutableFile(atPath: "/usr/sbin/lsof") else { return [] }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcfnt"]
        process.environment = ["LC_ALL": "C", "LANG": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            var data: Data {
                get { lock.withLock { storage } }
                set { lock.withLock { storage = newValue } }
            }
        }
        let box = OutputBox()
        let group = DispatchGroup()
        let reader = pipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            group.leave()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return []
        }
        try? pipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(3.0)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if !shouldContinue() || Date() >= deadline {
                process.terminate()
                if done.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 0.5)
                }
                _ = group.wait(timeout: .now() + 0.5)
                return []
            }
        }
        guard group.wait(timeout: .now() + 0.5) == .success, shouldContinue(),
              process.terminationStatus == 0,
              let text = String(data: box.data, encoding: .utf8) else { return [] }
        return parseLsofFieldOutput(text)
    }

    static func parseLsofFieldOutput(_ output: String) -> [ListeningPortItem] {
        var items: [ListeningPortItem] = []
        var seen = Set<String>()
        var currentPID: pid_t = 0
        var currentCommand = "未知进程"
        var currentSocketType: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p":
                currentPID = pid_t(value) ?? 0
                currentCommand = "未知进程"
                currentSocketType = nil
            case "c":
                currentCommand = value.replacingOccurrences(of: "\\x20", with: " ")
            case "f":
                currentSocketType = nil
            case "t":
                currentSocketType = value
            case "n":
                guard currentPID > 0, let colonIndex = value.lastIndex(of: ":") else { continue }
                let portText = value[value.index(after: colonIndex)...]
                guard let port = Int(portText), (1...65535).contains(port) else { continue }
                let hostPart = String(value[..<colonIndex])
                let displayAddress: String
                if hostPart == "*" {
                    switch currentSocketType {
                    case "IPv4": displayAddress = "0.0.0.0:\(port)"
                    case "IPv6": displayAddress = "[::]:\(port)"
                    default: continue
                    }
                } else {
                    guard !hostPart.isEmpty else { continue }
                    displayAddress = "\(hostPart):\(port)"
                }
                let dedupeKey = "\(currentPID)-\(displayAddress)"
                guard seen.insert(dedupeKey).inserted else { continue }
                items.append(
                    ListeningPortItem(
                        port: port,
                        address: displayAddress,
                        pid: currentPID,
                        processName: currentCommand
                    )
                )
            default:
                break
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            return lhs.processName.localizedStandardCompare(rhs.processName) == .orderedAscending
        }
    }
}
