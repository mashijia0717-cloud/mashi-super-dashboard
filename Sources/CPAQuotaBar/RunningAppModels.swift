import Foundation

enum RunningAppsSortMode: String, CaseIterable, Sendable {
    case memory
    case cpu
    case duration
    case name

    var title: String {
        switch self {
        case .memory: "内存"
        case .cpu: "CPU"
        case .duration: "运行时长"
        case .name: "名称"
        }
    }
}

enum RunningPageSubmode: String, CaseIterable, Sendable {
    case apps
    case ports

    var title: String {
        switch self {
        case .apps: "应用"
        case .ports: "端口"
        }
    }
}

struct ListeningPortItem: Identifiable, Hashable, Sendable {
    let port: Int
    let address: String
    let pid: pid_t
    let processName: String

    var id: String { "\(pid)-\(address)-\(port)" }

    var browserURL: URL? {
        URL(string: "http://127.0.0.1:\(port)")
    }
}

/// Process identity remains stable across refreshes and protects against PID reuse.
struct RunningAppIdentity: Hashable, Sendable, Codable {
    let processIdentifier: pid_t
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

enum RunningAppMemoryMeasurement: Sendable, Hashable {
    case physicalFootprint
    case resident
}

struct RunningApp: Identifiable, Hashable, Sendable {
    let identity: RunningAppIdentity
    let localizedName: String
    let bundleIdentifier: String?
    let executableURL: URL?
    let residentMemoryBytes: UInt64
    let cpuUsage: Double?
    let runningDuration: TimeInterval
    let memoryDeltaBytes: Int64
    let recentMemoryDeltaBytes: Int64?
    let memorySampleInterval: TimeInterval?
    let memoryMeasurement: RunningAppMemoryMeasurement
    let isActive: Bool

    init(
        identity: RunningAppIdentity,
        localizedName: String,
        bundleIdentifier: String?,
        executableURL: URL?,
        residentMemoryBytes: UInt64,
        cpuUsage: Double?,
        runningDuration: TimeInterval,
        memoryDeltaBytes: Int64 = 0,
        recentMemoryDeltaBytes: Int64? = nil,
        memorySampleInterval: TimeInterval? = nil,
        memoryMeasurement: RunningAppMemoryMeasurement = .physicalFootprint,
        isActive: Bool = false
    ) {
        self.identity = identity
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
        self.executableURL = executableURL
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuUsage = cpuUsage
        self.runningDuration = runningDuration
        self.memoryDeltaBytes = memoryDeltaBytes
        self.recentMemoryDeltaBytes = recentMemoryDeltaBytes
        self.memorySampleInterval = memorySampleInterval
        self.memoryMeasurement = memoryMeasurement
        self.isActive = isActive
    }

    var id: RunningAppIdentity { identity }

    var energyLevel: String {
        guard let cpuUsage else { return "能耗未知" }
        if cpuUsage >= 0.45 { return "高能耗" }
        if cpuUsage >= 0.10 { return "中等能耗" }
        return "低能耗"
    }
}

/// Input independent from AppKit and libproc, suitable for unit tests.
struct RunningAppCandidate: Equatable, Sendable {
    let identity: RunningAppIdentity
    var processIdentifier: pid_t { identity.processIdentifier }
    let localizedName: String?
    let bundleIdentifier: String?
    let executableURL: URL?
    let isRegular: Bool
    let isCurrentApplication: Bool
    let isActive: Bool

    init(
        identity: RunningAppIdentity,
        localizedName: String?,
        bundleIdentifier: String?,
        executableURL: URL?,
        isRegular: Bool,
        isCurrentApplication: Bool,
        isActive: Bool = false
    ) {
        self.identity = identity
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
        self.executableURL = executableURL
        self.isRegular = isRegular
        self.isCurrentApplication = isCurrentApplication
        self.isActive = isActive
    }
}

enum RunningAppHelpers {
    static func memoryChange(from previous: UInt64, to current: UInt64) -> Int64 {
        if current >= previous { return Int64(clamping: current - previous) }
        return -Int64(clamping: previous - current)
    }

    static func eligibleCandidates(_ candidates: [RunningAppCandidate]) -> [RunningAppCandidate] {
        candidates.filter {
            $0.isRegular && !$0.isCurrentApplication && $0.processIdentifier > 0
        }
    }

    static func sortedByResidentMemory(_ apps: [RunningApp]) -> [RunningApp] {
        apps.sorted { left, right in
            if left.residentMemoryBytes != right.residentMemoryBytes {
                return left.residentMemoryBytes > right.residentMemoryBytes
            }
            let nameOrder = left.localizedName.localizedStandardCompare(right.localizedName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            if left.identity.processIdentifier != right.identity.processIdentifier {
                return left.identity.processIdentifier < right.identity.processIdentifier
            }
            if left.identity.startTimeSeconds != right.identity.startTimeSeconds {
                return left.identity.startTimeSeconds < right.identity.startTimeSeconds
            }
            return left.identity.startTimeMicroseconds < right.identity.startTimeMicroseconds
        }
    }

    static func identityMatches(expected: RunningAppIdentity, observed: RunningAppIdentity?) -> Bool {
        expected == observed
    }
}

enum RunningAppTerminationResult: Equatable, Sendable {
    case terminated
    case applicationNotRunning
    case identityChanged
    case requestRejected
}
