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

/// Process identity remains stable across refreshes and protects against PID reuse.
struct RunningAppIdentity: Hashable, Sendable, Codable {
    let processIdentifier: pid_t
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

struct RunningApp: Identifiable, Hashable, Sendable {
    let identity: RunningAppIdentity
    let localizedName: String
    let bundleIdentifier: String?
    let executableURL: URL?
    let residentMemoryBytes: UInt64
    let cpuUsage: Double?
    let runningDuration: TimeInterval

    var id: RunningAppIdentity { identity }

    var energyLevel: String {
        guard let cpuUsage else { return "能耗未知" }
        if cpuUsage >= 0.20 { return "高能耗" }
        if cpuUsage >= 0.06 { return "中等能耗" }
        return "低能耗"
    }
}

/// Input independent from AppKit and libproc, suitable for unit tests.
struct RunningAppCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
    let executableURL: URL?
    let isRegular: Bool
    let isCurrentApplication: Bool
}

enum RunningAppHelpers {
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
