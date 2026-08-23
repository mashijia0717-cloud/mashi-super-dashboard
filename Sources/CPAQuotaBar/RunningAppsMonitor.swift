import AppKit
import Darwin
import Foundation

struct RunningAppsMonitor: Sendable {
    typealias ProcessInfoProvider = @Sendable (pid_t) -> proc_bsdinfo?
    typealias ResidentMemoryProvider = @Sendable (pid_t) -> UInt64?
    typealias CPUTimeProvider = @Sendable (pid_t) -> UInt64?

    private let processInfoProvider: ProcessInfoProvider
    private let residentMemoryProvider: ResidentMemoryProvider
    private let cpuTimeProvider: CPUTimeProvider
    private let samplingState = RunningAppSamplingState()

    init(
        processInfoProvider: @escaping ProcessInfoProvider = Self.readProcessInfo,
        residentMemoryProvider: @escaping ResidentMemoryProvider = Self.readResidentMemory,
        cpuTimeProvider: @escaping CPUTimeProvider = Self.readCPUTime
    ) {
        self.processInfoProvider = processInfoProvider
        self.residentMemoryProvider = residentMemoryProvider
        self.cpuTimeProvider = cpuTimeProvider
    }

    @MainActor
    func candidates() -> [RunningAppCandidate] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.map { application in
            RunningAppCandidate(
                processIdentifier: application.processIdentifier,
                localizedName: application.localizedName,
                bundleIdentifier: application.bundleIdentifier,
                executableURL: application.executableURL,
                isRegular: application.activationPolicy == .regular,
                isCurrentApplication: application.processIdentifier == currentPID
            )
        }
    }

    func sample(_ candidates: [RunningAppCandidate]) -> [RunningApp] {
        let apps = RunningAppHelpers.eligibleCandidates(candidates).compactMap { candidate -> RunningApp? in
            guard let initialInfo = processInfoProvider(candidate.processIdentifier), initialInfo.pbi_status != SZOMB,
                  let residentMemoryBytes = residentMemoryProvider(candidate.processIdentifier),
                  let finalInfo = processInfoProvider(candidate.processIdentifier), finalInfo.pbi_status != SZOMB else {
                return nil
            }
            let initialIdentity = Self.identity(processIdentifier: candidate.processIdentifier, info: initialInfo)
            let finalIdentity = Self.identity(processIdentifier: candidate.processIdentifier, info: finalInfo)
            guard initialIdentity == finalIdentity else { return nil }
            let cpuUsage = cpuTimeProvider(candidate.processIdentifier).flatMap {
                samplingState.usage(
                    identity: finalIdentity,
                    cpuTimeNanoseconds: $0,
                    sampledAt: Date()
                )
            }
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
                runningDuration: max(0, Date().timeIntervalSince(startDate))
            )
        }
        return RunningAppHelpers.sortedByResidentMemory(apps)
    }

    /// Revalidates process start time immediately before requesting force termination.
    @MainActor
    func forceTerminate(_ identity: RunningAppIdentity) -> RunningAppTerminationResult {
        guard let application = NSRunningApplication(processIdentifier: identity.processIdentifier),
              !application.isTerminated else {
            return .applicationNotRunning
        }
        guard let info = processInfoProvider(identity.processIdentifier) else {
            return .applicationNotRunning
        }
        let observed = Self.identity(processIdentifier: identity.processIdentifier, info: info)
        guard RunningAppHelpers.identityMatches(expected: identity, observed: observed) else {
            return .identityChanged
        }
        return application.forceTerminate() ? .terminated : .requestRejected
    }

    static func identity(processIdentifier: pid_t, info: proc_bsdinfo) -> RunningAppIdentity {
        RunningAppIdentity(
            processIdentifier: processIdentifier,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    static func readResidentMemory(processIdentifier: pid_t) -> UInt64? {
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
        return taskInfo.pti_resident_size
    }

    static func readCPUTime(processIdentifier: pid_t) -> UInt64? {
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
        return taskInfo.pti_total_user + taskInfo.pti_total_system
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

private final class RunningAppSamplingState: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [
        RunningAppIdentity: (cpuTimeNanoseconds: UInt64, sampledAt: Date)
    ] = [:]

    func usage(
        identity: RunningAppIdentity,
        cpuTimeNanoseconds: UInt64,
        sampledAt: Date
    ) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let old = previous[identity]
        previous[identity] = (cpuTimeNanoseconds, sampledAt)
        guard let old,
              cpuTimeNanoseconds >= old.cpuTimeNanoseconds else { return nil }
        let elapsed = sampledAt.timeIntervalSince(old.sampledAt)
        guard elapsed > 0 else { return nil }
        let cpuSeconds = Double(cpuTimeNanoseconds - old.cpuTimeNanoseconds) / 1_000_000_000
        return min(max(cpuSeconds / elapsed, 0), 1)
    }
}
