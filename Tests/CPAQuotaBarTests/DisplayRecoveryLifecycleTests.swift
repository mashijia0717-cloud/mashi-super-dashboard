import AppKit
import Testing
@testable import CPAQuotaBar

@MainActor
private final class RecoveryRecorder {
    var calls: [[String]] = []
    var blocked: CheckedContinuation<DisplayConsolePaths.ExecResult, Never>?
    var blockNext = true
    var fail = false
    var deadlocked = false
    var active = 0
    var maximumActive = 0
    var delays: [Int] = []
    func run(_ path: String, _ args: [String]) async -> DisplayConsolePaths.ExecResult {
        calls.append([path] + args)
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if blockNext {
            blockNext = false
            return await withCheckedContinuation { blocked = $0 }
        }
        return .init(code: fail ? 1 : 0, output: fail ? "display unavailable" : "no-owned-state")
    }
    func release() { blocked?.resume(returning: .init(code: 0, output: "no-owned-state")); blocked = nil }
    func controller() -> DisplaySafetyRecoveryController {
        .init(helper: { $0 }, command: { [self] in await run($0, $1) }, wait: { [self] in delays.append($0) }, deadlockCheck: { [self] in deadlocked })
    }
}

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 { if condition() { return true }; await Task.yield() }
    return condition()
}

@Test @MainActor func recoveryBurstNeverOverlapsAnUncancelledOldHelper() async {
    let log = RecoveryRecorder(), controller = log.controller()
    controller.requestRecovery()
    #expect(await eventually { log.blocked != nil })
    for _ in 0..<100 { controller.requestRecovery() }
    #expect(log.calls.count == 1)
    log.release()
    #expect(await eventually { log.calls.count == 3 && log.active == 0 })
    #expect(log.maximumActive == 1)
    #expect(log.calls.map { $0.last! } == ["--recover-orphan", "--recover-orphan", "safety-recover"])
    controller.stop()
}

@Test @MainActor func screenSleepInvalidatesTheOldCompletionAndWakeStartsFresh() async {
    let log = RecoveryRecorder(), controller = log.controller()
    controller.requestRecovery()
    #expect(await eventually { log.blocked != nil })
    controller.noteSleep()
    for _ in 0..<50 { controller.requestRecovery() }
    log.release()
    for _ in 0..<30 { await Task.yield() }
    #expect(log.calls.count == 1)
    controller.noteWake()
    #expect(await eventually { log.calls.count == 3 && log.active == 0 })
    #expect(log.maximumActive == 1)
    controller.stop()
}

@Test @MainActor func failedRecoveryStopsAfterFourAttemptsAndNewEventCanRetry() async {
    let log = RecoveryRecorder(); log.blockNext = false; log.fail = true
    let controller = log.controller()
    controller.requestRecovery()
    #expect(await eventually { log.calls.count == 4 && log.active == 0 })
    for _ in 0..<30 { await Task.yield() }
    #expect(log.calls.count == 4)
    #expect(log.delays == [250, 250, 750, 2000])
    log.fail = false; controller.requestRecovery()
    #expect(await eventually { log.calls.count == 6 })
    #expect(log.calls.last?.last == "safety-recover")
    controller.stop()
}

@Test @MainActor func stopDoesNotLetOldCompletionLaunchAnotherCommand() async {
    let log = RecoveryRecorder(), controller = log.controller()
    controller.requestRecovery()
    #expect(await eventually { log.blocked != nil })
    controller.stop(); controller.requestRecovery(); log.release()
    for _ in 0..<30 { await Task.yield() }
    #expect(log.calls.count == 1)
}

@Test @MainActor func openLidHeadlessUnplugBreaksScreenSleepDeadlockAndForwardsRemovalID() async {
    let log = RecoveryRecorder(); log.blockNext = false; log.deadlocked = true
    let controller = log.controller()
    controller.requestRecovery(removedExternal: 3)
    controller.noteScreenSleep()
    #expect(await eventually { log.calls.count == 2 && log.active == 0 })
    #expect(log.calls[0] == ["ScreenBlank", "--recover-orphan", "--observed-removal"])
    #expect(log.calls[1] == ["DisplayManager", "safety-recover", "--observed-removal", "3"])
    controller.stop()
}
