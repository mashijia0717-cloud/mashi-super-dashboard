import AppKit
import Darwin
import Foundation
import Testing
@testable import CPAQuotaBar

@Suite
struct MemoryCleanupTests {
    @Test func lowRateSwapActivityIsNotReportedAsIdle() {
        #expect(memorySnapshot(swapIns: 0.01).isSwapActive)
        #expect(memorySnapshot(swapOuts: 7).isSwapActive)
        #expect(!memorySnapshot().isSwapActive)
        #expect(!memorySnapshot(swapIns: .nan, swapOuts: -1).isSwapActive)
    }

    @Test func physicalCompositionUsesPhysicalCompressedBytesAndIncludesAvailableCache() {
        let snapshot = memorySnapshot()
        #expect(snapshot.usedBytes == 512)
        #expect(snapshot.availableBytes == 512)
        #expect(snapshot.usedFraction == 0.5)
        #expect(snapshot.physicalCompositionFractions == [0.25, 0.125, 0.125, 0.25])
        #expect(snapshot.compressionSavedBytes == 384)
    }

    @Test func inconsistentCompositionCannotOverflowTheBarOrUnderflowSavings() {
        let snapshot = memorySnapshot(total: 1024, app: 512, wired: 256, compressed: 256, cached: .max)
        #expect(snapshot.physicalCompositionFractions == [0.5, 0.25, 0.25, 0])
        #expect(memorySnapshot(total: 0).physicalCompositionFractions == [0, 0, 0, 0])
        #expect(memorySnapshot(compressed: 1024).compressionSavedBytes == 0)
        let extreme = memorySnapshot(total: .max, app: .max, wired: .max, compressed: .max, cached: .max)
        #expect(extreme.physicalCompositionFractions == [1, 0, 0, 0])
    }

    @Test func comparisonReportsBothDirectionsAndSmallChangesWithoutOverflow() {
        #expect(comparison(before: 100, after: 101).change == .increased(1))
        #expect(comparison(before: 100, after: 99).change == .decreased(1))
        #expect(comparison(before: 100, after: 100).change == .unchanged)
        #expect(comparison(before: 0, after: .max).change == .increased(.max))
        #expect(comparison(before: .max, after: 0).change == .decreased(.max))
        #expect(comparison(before: .max, after: .max).message.contains("暂无变化"))
    }

    @Test func incompleteSamplesAndUnconfirmedExitsStayExplicit() {
        #expect(comparison(before: nil, after: 100).change == .unavailable)
        #expect(comparison(before: 100, after: nil).message.contains("采样不完整"))
        let result = MemoryCleanupComparison(
            beforeAvailable: 100, afterAvailable: 80,
            confirmedTerminationCount: 1, requestedTerminationCount: 3
        )
        #expect(result.message.contains("减少"))
        #expect(result.message.contains("已确认退出 1/3"))
        #expect(!result.message.contains("净腾出"))
    }

    @Test func recentMemoryTrendCanFallWhileRemainingAboveBaseline() {
        let state = RunningAppSamplingState()
        let first = record(state, bytes: 100, seconds: 1)
        let growth = record(state, bytes: 200, seconds: 3)
        let decline = record(state, bytes: 150, seconds: 6)
        #expect(first.recent == nil)
        #expect(growth.baseline == 100)
        #expect(growth.recent == 100)
        #expect(decline.baseline == 50)
        #expect(decline.recent == -50)
        #expect(decline.interval == 3)
    }

    @Test func measurementChangesResetTheTrendInsteadOfInventingGrowth() {
        let state = RunningAppSamplingState()
        _ = record(state, bytes: 100, seconds: 1)
        let fallback = record(state, bytes: 800, seconds: 2, measurement: .resident)
        #expect(fallback.baseline == 0)
        #expect(fallback.recent == nil)
        let following = record(state, bytes: 700, seconds: 3, measurement: .resident)
        #expect(following.recent == -100)
        #expect(record(state, bytes: 100, seconds: 4).recent == nil)
    }

    @Test func outOfOrderSamplesDoNotPoisonTheFollowingMemoryAndCPUDeltas() {
        let state = RunningAppSamplingState()
        _ = record(state, bytes: 100, seconds: 10)
        #expect(record(state, bytes: 900, seconds: 9).recent == nil)
        #expect(record(state, bytes: 150, seconds: 11).recent == 50)
        #expect(state.usage(identity: memoryIdentity, cpuTimeNanoseconds: 1_000_000_000, sampledAt: date(10)) == nil)
        #expect(state.usage(identity: memoryIdentity, cpuTimeNanoseconds: 100, sampledAt: date(9)) == nil)
        #expect(state.usage(identity: memoryIdentity, cpuTimeNanoseconds: 1_500_000_000, sampledAt: date(11)) == 0.5)
    }

    @Test func memoryChangesSaturateInsteadOfOverflowing() {
        #expect(RunningAppHelpers.memoryChange(from: 0, to: .max) == Int64.max)
        #expect(RunningAppHelpers.memoryChange(from: .max, to: 0) == -Int64.max)
    }

    @Test func transientReadFailuresKeepTheBaselineButGoneAppsResetIt() throws {
        let fixture = MemoryProcessFixture()
        let monitor = fixture.monitor()
        let candidate = memoryCandidate()
        let first = try #require(monitor.sample([candidate], sampledAt: date(1)).first)
        #expect(first.recentMemoryDeltaBytes == nil)
        fixture.setMemory(nil)
        #expect(monitor.sample([candidate], sampledAt: date(2)).isEmpty)
        fixture.setMemory(150)
        let recovered = try #require(monitor.sample([candidate], sampledAt: date(3)).first)
        #expect(recovered.memoryDeltaBytes == 50)
        #expect(recovered.recentMemoryDeltaBytes == 50)
        #expect(recovered.memorySampleInterval == 2)
        _ = monitor.sample([], sampledAt: date(4))
        let restarted = try #require(monitor.sample([candidate], sampledAt: date(5)).first)
        #expect(restarted.recentMemoryDeltaBytes == nil)
    }

    @Test func identityIsRecheckedAfterCPUAndMemoryReads() {
        let fixture = MemoryProcessFixture(reusePIDDuringCPURead: true)
        #expect(fixture.monitor().sample([memoryCandidate()], sampledAt: date(1)).isEmpty)
    }

    @Test func exitConfirmationDistinguishesRunningReusedMissingAndUnreadableProcesses() {
        let running = RunningAppsMonitor(processInfoProvider: { _ in processInfo(start: 10) })
        #expect(running.isIdentityRunning(memoryIdentity) == true)
        let reused = RunningAppsMonitor(processInfoProvider: { _ in processInfo(start: 11) })
        #expect(reused.isIdentityRunning(memoryIdentity) == false)
        let zombie = RunningAppsMonitor(processInfoProvider: { _ in processInfo(start: 10, status: UInt32(SZOMB)) })
        #expect(zombie.isIdentityRunning(memoryIdentity) == false)
        let gone = RunningAppsMonitor(processInfoProvider: { _ in nil }, processExistenceProvider: { _ in false })
        #expect(gone.isIdentityRunning(memoryIdentity) == false)
        let unreadable = RunningAppsMonitor(processInfoProvider: { _ in nil }, processExistenceProvider: { _ in true })
        #expect(unreadable.isIdentityRunning(memoryIdentity) == nil)
        let unknown = RunningAppsMonitor(processInfoProvider: { _ in nil }, processExistenceProvider: { _ in nil })
        #expect(unknown.isIdentityRunning(memoryIdentity) == nil)
        #expect(gone.isIdentityRunning(.init(processIdentifier: 0, startTimeSeconds: 0, startTimeMicroseconds: 0)) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct MemoryCleanupViewTests {
    @Test func cleaningDisablesAppActionsAndCompletionClearsVisibleCheckboxes() throws {
        _ = NSApplication.shared
        let view = MemoryCleanupDashboardView(frame: .zero)
        let app = memoryApp(bytes: 600 * 1024 * 1024)
        view.update(memory: memorySnapshot(), apps: [app])
        try button("勾选后台大户", in: view).performClick(nil)
        #expect(try checkbox(in: view).state == .on)
        view.setCleaning(true)
        view.update(memory: memorySnapshot(), apps: [app])
        #expect(try !checkbox(in: view).isEnabled)
        #expect(try !button("退出", in: view).isEnabled)
        view.setCleaning(false)
        view.showComparisonResult(beforeAvailable: 512, afterAvailable: 400, closedCount: 0, requestedCount: 1)
        #expect(try checkbox(in: view).state == .off)
        #expect(try button("整理自身缓存", in: view).isEnabled)
        #expect(labels(in: view).contains { $0.stringValue.contains("减少") && $0.stringValue.contains("0/1") })
    }

    @Test func backgroundSelectionDoesNotSilentlySelectSmallApps() throws {
        _ = NSApplication.shared
        let view = MemoryCleanupDashboardView(frame: .zero)
        view.update(memory: memorySnapshot(), apps: [memoryApp(bytes: 100 * 1024 * 1024)])
        let select = try button("无后台大户", in: view)
        #expect(!select.isEnabled)
        select.performClick(nil)
        #expect(try checkbox(in: view).state == .off)
    }

    @Test func displayUsesRecentTrendAndReportsFailedSamples() {
        _ = NSApplication.shared
        let view = MemoryCleanupDashboardView(frame: .zero)
        let app = memoryApp(bytes: 100 * 1024 * 1024, baseline: 80 * 1024 * 1024, recent: -40 * 1024 * 1024)
        view.update(memory: memorySnapshot(), apps: [app])
        #expect(labels(in: view).contains { $0.stringValue.contains("↓") })
        view.update(memory: nil, apps: [app])
        view.showComparisonResult(beforeAvailable: 512, afterAvailable: nil, closedCount: 0)
        #expect(labels(in: view).contains { $0.stringValue.contains("采样不完整") })
        #expect(labels(in: view).contains { $0.stringValue.contains("采样失败") })
    }

    @Test func extremeNegativeTrendDoesNotOverflowDuringFormatting() {
        _ = NSApplication.shared
        let view = MemoryCleanupDashboardView(frame: .zero)
        view.update(memory: memorySnapshot(), apps: [memoryApp(bytes: 100, baseline: .min, recent: .min)])
        #expect(labels(in: view).contains { $0.stringValue.contains("↓") })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func checkbox(in view: NSView) throws -> NSButton {
        try #require(descendants(view).compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("appCheckToggled:") })
    }

    private func labels(in view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }
    }
}

private let memoryIdentity = RunningAppIdentity(processIdentifier: 41234, startTimeSeconds: 10, startTimeMicroseconds: 0)

private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func comparison(before: UInt64?, after: UInt64?) -> MemoryCleanupComparison {
    MemoryCleanupComparison(beforeAvailable: before, afterAvailable: after, confirmedTerminationCount: 0, requestedTerminationCount: 0)
}

private func record(
    _ state: RunningAppSamplingState, bytes: UInt64, seconds: TimeInterval,
    measurement: RunningAppMemoryMeasurement = .physicalFootprint
) -> (baseline: Int64, recent: Int64?, interval: TimeInterval?) {
    state.recordMemoryAndDelta(identity: memoryIdentity, memoryBytes: bytes, measurement: measurement, sampledAt: date(seconds))
}

private func memorySnapshot(
    total: UInt64 = 1024, app: UInt64 = 256, wired: UInt64 = 128, compressed: UInt64 = 128,
    cached: UInt64 = 256, swapIns: Double = 0, swapOuts: Double = 0
) -> MemoryCompositionSnapshot {
    let used = [app, wired, compressed].reduce(UInt64(0)) { accumulated, bytes in
        accumulated + min(bytes, total - accumulated)
    }
    return MemoryCompositionSnapshot(
        totalBytes: total, usedBytes: used, availableBytes: total - used,
        appBytes: app, wiredBytes: wired, compressedBytes: compressed,
        uncompressedInCompressorBytes: 512, cachedBytes: cached, freeBytes: 256,
        swapUsedBytes: 0, swapTotalBytes: 0, swapInsPerSecond: swapIns, swapOutsPerSecond: swapOuts,
        pageInsTotal: 0, pageOutsTotal: 0, pressureLevel: 1, pressureLabel: "正常", sampledAt: date(10)
    )
}

private func memoryCandidate(identity: RunningAppIdentity = memoryIdentity, name: String = "测试应用") -> RunningAppCandidate {
    RunningAppCandidate(
        identity: identity, localizedName: name, bundleIdentifier: nil,
        executableURL: nil, isRegular: true, isCurrentApplication: false
    )
}

private func memoryApp(bytes: UInt64, baseline: Int64 = 0, recent: Int64? = nil) -> RunningApp {
    RunningApp(
        identity: memoryIdentity, localizedName: "测试应用", bundleIdentifier: nil, executableURL: nil,
        residentMemoryBytes: bytes, cpuUsage: nil, runningDuration: 10, memoryDeltaBytes: baseline,
        recentMemoryDeltaBytes: recent, memorySampleInterval: recent == nil ? nil : 2
    )
}

private func processInfo(start: UInt64, microseconds: UInt64 = 0, status: UInt32 = 2) -> proc_bsdinfo {
    var info = proc_bsdinfo()
    info.pbi_start_tvsec = start
    info.pbi_start_tvusec = microseconds
    info.pbi_status = status
    return info
}

private final class MemoryProcessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: UInt64? = 100
    private var start: UInt64 = 10
    private let reusePIDDuringCPURead: Bool

    init(reusePIDDuringCPURead: Bool = false) {
        self.reusePIDDuringCPURead = reusePIDDuringCPURead
    }

    func setMemory(_ value: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        memory = value
    }

    func monitor() -> RunningAppsMonitor {
        RunningAppsMonitor(
            processInfoProvider: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                return processInfo(start: start)
            },
            residentMemoryProvider: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                return memory
            },
            cpuTimeProvider: { [self] _ in
                lock.lock()
                defer { lock.unlock() }
                if reusePIDDuringCPURead { start += 1 }
                return 1_000_000_000
            }
        )
    }
}

@Suite
struct ProcessIdentityTests {
    @Test func candidateCaptureRejectsPIDReuseWhileReadingMetadata() {
        let fixture = ProcessIdentityFixture()
        let candidate = fixture.monitor().captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { identity in
            #expect(identity == memoryIdentity)
            fixture.replaceInfo(processInfo(start: 10, microseconds: 1))
            return memoryCandidate(identity: identity, name: "Original app")
        }
        #expect(candidate == nil)
    }

    @Test func candidateCaptureRejectsMissingZombieAndMismatchedIdentities() {
        let unavailable: [proc_bsdinfo?] = [nil, processInfo(start: 10, status: UInt32(SZOMB))]
        for info in unavailable {
            let fixture = ProcessIdentityFixture(info: info)
            let candidate = fixture.monitor().captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { identity in
                Issue.record("Unavailable processes must not supply application metadata")
                return memoryCandidate(identity: identity)
            }
            #expect(candidate == nil)
        }
        let fixture = ProcessIdentityFixture()
        let other = RunningAppIdentity(processIdentifier: memoryIdentity.processIdentifier, startTimeSeconds: 11, startTimeMicroseconds: 0)
        #expect(fixture.monitor().captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { _ in
            memoryCandidate(identity: other)
        } == nil)
    }

    @Test func candidateCaptureRejectsDisappearanceDuringMetadataRead() {
        let fixture = ProcessIdentityFixture()
        let candidate = fixture.monitor().captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { identity in
            fixture.replaceInfo(nil)
            return memoryCandidate(identity: identity)
        }
        #expect(candidate == nil)
    }

    @Test func reusedPIDCannotAttachReplacementMetricsToOldApplicationMetadata() throws {
        let fixture = ProcessIdentityFixture()
        let monitor = fixture.monitor()
        let candidate = try #require(monitor.captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { identity in
            memoryCandidate(identity: identity, name: "Original app")
        })
        fixture.replaceInfo(processInfo(start: 10, microseconds: 1))
        #expect(monitor.sample([candidate]).isEmpty)
        #expect(fixture.metricReadCount == 0)
        let replacement = try #require(monitor.captureCandidate(processIdentifier: memoryIdentity.processIdentifier) { identity in
            memoryCandidate(identity: identity, name: "Replacement app")
        })
        let app = try #require(monitor.sample([replacement]).first)
        #expect(app.localizedName == "Replacement app")
        #expect(app.identity == replacement.identity)
        #expect(app.identity != candidate.identity)
        #expect(app.memoryDeltaBytes == 0)
        #expect(app.cpuUsage == nil)
    }

    @Test @MainActor func staleIdentityCannotEvenPrepareTermination() {
        let fixture = ProcessIdentityFixture(info: processInfo(start: 11))
        let result = fixture.monitor().requestTermination(memoryIdentity) {
            Issue.record("A reused PID must not prepare a termination request")
            return { Issue.record("A reused PID must not receive a termination request"); return true }
        }
        #expect(result == .identityChanged)
    }

    @Test @MainActor func reuseWhilePreparingTerminationCannotReachTheRequest() {
        let fixture = ProcessIdentityFixture()
        var requests = 0
        let result = fixture.monitor().requestTermination(memoryIdentity) {
            fixture.replaceInfo(processInfo(start: 10, microseconds: 1))
            return { requests += 1; return true }
        }
        #expect(result == .identityChanged)
        #expect(requests == 0)
    }

    @Test @MainActor func disappearanceAndZombiesDuringTerminationPreparationCannotReachTheRequest() {
        let unavailable: [proc_bsdinfo?] = [nil, processInfo(start: 10, status: UInt32(SZOMB))]
        for info in unavailable {
            let fixture = ProcessIdentityFixture()
            var requests = 0
            let result = fixture.monitor().requestTermination(memoryIdentity) {
                fixture.replaceInfo(info)
                return { requests += 1; return true }
            }
            #expect(result == .applicationNotRunning)
            #expect(requests == 0)
        }
    }

    @Test(arguments: [true, false]) @MainActor func stableIdentityPreservesTerminationRequestResult(accepted: Bool) {
        let fixture = ProcessIdentityFixture()
        var requests = 0
        let result = fixture.monitor().requestTermination(memoryIdentity) {
            { requests += 1; return accepted }
        }
        #expect(result == (accepted ? .terminated : .requestRejected))
        #expect(requests == 1)
    }
}

@Suite
struct ListeningPortIdentityTests {
    @Test func dualStackWildcardsKeepSeparateAddressesAndIDs() {
        let items = ListeningPortScanner.parseLsofFieldOutput("""
        p41234
        cnode
        f10
        tIPv4
        n*:3000
        f11
        tIPv6
        n*:3000
        f12
        tIPv4
        n*:3000
        f13
        tIPv6
        n[::]:3000
        """)
        #expect(items.count == 2)
        #expect(Set(items.map(\.address)) == ["0.0.0.0:3000", "[::]:3000"])
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.allSatisfy { $0.pid == memoryIdentity.processIdentifier && $0.processName == "node" })
    }

    @Test func socketTypeAndCommandCannotLeakIntoFollowingRecords() {
        let items = ListeningPortScanner.parseLsofFieldOutput("""
        p41234
        cfirst
        f10
        tIPv6
        n*:3000
        f11
        n*:3001
        p41235
        n*:3002
        f12
        tIPv4
        n*:3003
        f13
        tUNKNOWN
        n*:3004
        """)
        #expect(items.map(\.port) == [3000, 3003])
        #expect(items.map(\.address) == ["[::]:3000", "0.0.0.0:3003"])
        #expect(items.last?.processName == "未知进程")
    }

    @Test func concreteAddressesAndValidPortBoundsSurviveParsing() {
        let items = ListeningPortScanner.parseLsofFieldOutput("""
        p41234
        cnode
        f10
        tIPv4
        n127.0.0.1:1
        f11
        tIPv6
        n[::1]:65535
        f12
        tIPv4
        n*:0
        f13
        tIPv6
        n*:65536
        f14
        tIPv4
        n*:invalid
        """)
        #expect(items.map(\.address) == ["127.0.0.1:1", "[::1]:65535"])
    }

    @Test(arguments: ["IPv4", "IPv6"]) func changedWildcardFamilyCannotAuthorizePortTermination(originalFamily: String) throws {
        let replacementFamily = originalFamily == "IPv4" ? "IPv6" : "IPv4"
        let original = try #require(ListeningPortScanner.parseLsofFieldOutput("p41234\ncnode\nf10\nt\(originalFamily)\nn*:3000\n").first)
        let replacement = try #require(ListeningPortScanner.parseLsofFieldOutput("p41234\ncnode\nf10\nt\(replacementFamily)\nn*:3000\n").first)
        let identity = ListeningPortProcessController.Identity(
            process: memoryIdentity, effectiveUserID: 501, realUserID: 501, executablePath: "/opt/homebrew/bin/node"
        )
        let operations = ListeningPortProcessController.Operations(
            currentUserID: 501, protectedProcessIDs: [], readIdentity: { _ in identity },
            readListeners: { [replacement] },
            sendSignal: { _, _ in Issue.record("A different socket family must never authorize a signal"); return 0 },
            shouldContinue: { true }
        )
        let result = ListeningPortProcessController.terminateSafely(.init(item: original, identity: identity), using: operations)
        if case .failure(.listenerNotVerified) = result { return }
        Issue.record("Expected the changed wildcard family to fail listener revalidation")
    }
}

private final class ProcessIdentityFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var info: proc_bsdinfo?
    private var metricReads = 0

    init(info: proc_bsdinfo? = processInfo(start: 10)) {
        self.info = info
    }

    var metricReadCount: Int { lock.withLock { metricReads } }

    func replaceInfo(_ value: proc_bsdinfo?) {
        lock.withLock { info = value }
    }

    func monitor() -> RunningAppsMonitor {
        RunningAppsMonitor(
            processInfoProvider: { [self] _ in lock.withLock { info } },
            residentMemoryProvider: { [self] _ in lock.withLock { metricReads += 1; return 100 } },
            cpuTimeProvider: { [self] _ in lock.withLock { metricReads += 1; return 1_000_000_000 } },
            processExistenceProvider: { _ in nil }
        )
    }
}
