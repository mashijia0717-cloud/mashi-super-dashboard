import AppKit
import CoreAudio
import Darwin
import Foundation
import Testing
@testable import CPAQuotaBar

struct ToolboxProbeTests {
    @Test func cancellationBeforeContinuationInstallationCompletesWithoutStartingWork() async {
        let gate = LatencyProbeGate()
        gate.finish(nil)
        let value = await withCheckedContinuation { continuation in
            #expect(!gate.install(continuation, connection: nil, timeoutWork: nil))
        }
        #expect(value == nil)
    }

    @Test func competingProbeCompletionsResumeOnlyOnce() async {
        let gate = LatencyProbeGate()
        let value = await withCheckedContinuation { continuation in
            #expect(gate.install(continuation, connection: nil, timeoutWork: nil))
            DispatchQueue.concurrentPerform(iterations: 20) { index in gate.finish(index) }
        }
        #expect(value != nil)
        gate.finish(nil)
    }

    @Test func invalidProbeArgumentsNeverOpenConnections() async {
        #expect(await QuickLatencyProbe.tcpLatencyMilliseconds(host: "", port: 80) == nil)
        #expect(await QuickLatencyProbe.tcpLatencyMilliseconds(host: "127.0.0.1", port: 0) == nil)
        #expect(await QuickLatencyProbe.tcpLatencyMilliseconds(host: "127.0.0.1", port: 80, timeout: .nan) == nil)
    }

    @Test func cancelledProbeReturnsWithoutOpeningAConnection() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await QuickLatencyProbe.tcpLatencyMilliseconds(host: "127.0.0.1", port: 80)
        }
        #expect(await task.value == nil)
    }

    @Test func missingOrFailedEndpointsCannotProduceAnAllHealthyDiagnosis() {
        for values: (Int?, Int?, Int?, Bool) in [(nil, 10, 20, true), (1, nil, 20, true), (1, 10, nil, true), (nil, 10, 20, false), (nil, nil, nil, false)] {
            let diagnosis = NetworkProbeDiagnosis.evaluate(gateway: values.0, domestic: values.1, international: values.2, hasGateway: values.3)
            #expect(diagnosis.severity == .warning)
        }
        #expect(NetworkProbeDiagnosis.evaluate(gateway: 1, domestic: 10, international: 20, hasGateway: true).severity == .success)
        #expect(NetworkProbeDiagnosis.evaluate(gateway: 1, domestic: 500, international: 20, hasGateway: true).severity == .warning)
    }
}

struct ToolboxPeripheralTests {
    @Test func exhaustedBatteriesRemainVisibleAndInvalidReadingsAreRejected() {
        let empty = PeripheralBatteryScanner.battery(properties: ["Product": "Keyboard", "BatteryPercent": 0], registryID: 1)
        #expect(empty?.percent == 0)
        for value: NSNumber in [-1, 101, NSNumber(value: Double.nan), NSNumber(value: true)] {
            #expect(PeripheralBatteryScanner.battery(properties: ["Product": "Keyboard", "BatteryPercent": value], registryID: 1) == nil)
        }
    }

    @Test func disconnectedAndInternalDevicesAreExcluded() {
        #expect(PeripheralBatteryScanner.battery(properties: ["Product": "Keyboard", "BatteryPercent": 40, "Connected": false], registryID: 1) == nil)
        #expect(PeripheralBatteryScanner.battery(properties: ["Product": "Keyboard", "BatteryPercent": 40, "Transport": "SPI"], registryID: 1) == nil)
    }

    @Test func sameNamesKeepSeparateHardwareIdentities() {
        let properties: [String: Any] = ["Product": "Magic Mouse", "BatteryPercent": 20]
        let first = PeripheralBatteryScanner.battery(properties: properties, registryID: 1)
        let second = PeripheralBatteryScanner.battery(properties: properties, registryID: 2)
        #expect(first?.id != second?.id)
        let bluetooth = PeripheralBatteryScanner.battery(properties: properties.merging(["DeviceAddress": "AA:BB:CC:DD:EE:FF"]) { _, new in new }, registryID: 1)
        let duplicate = PeripheralBatteryScanner.battery(properties: properties.merging(["DeviceAddress": "aa-bb-cc-dd-ee-ff"]) { _, new in new }, registryID: 2)
        #expect(bluetooth?.id == duplicate?.id)
    }

    @Test func gHubMouseMergesWithMatchingHIDOrAppendsSortedByBatteryLevel() {
        let keyboard = WirelessPeripheralBattery(id: "bluetooth:11", name: "Magic Keyboard", symbol: "keyboard", percent: 55)
        let hidMouse = WirelessPeripheralBattery(id: "bluetooth:22", name: "G PRO X SUPERLIGHT", symbol: "computermouse", percent: 40)
        let merged = PeripheralBatteryScanner.merging(
            hid: [keyboard, hidMouse],
            gHub: GHubMouseBattery(name: "G PRO X SUPERLIGHT 2", percent: 38, isCharging: true)
        )
        #expect(merged.count == 2)
        #expect(merged[0].id == "bluetooth:22")
        #expect(merged[0].percent == 38)
        #expect(merged[0].isCharging)

        let appended = PeripheralBatteryScanner.merging(
            hid: [keyboard],
            gHub: GHubMouseBattery(name: "Logitech MX Master", percent: 25, isCharging: false)
        )
        #expect(appended.count == 2)
        #expect(appended[0].name == "Logitech MX Master")
        #expect(appended[0].percent == 25)
        #expect(appended[1].name == "Magic Keyboard")
    }
}

@MainActor
struct ToolboxUnifiedLayoutTests {
    @Test func redesignedToolboxHasThreeCardsAndFitsWithoutScrolling() {
        let toolbox = QuickToolboxDashboardView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 376, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = toolbox
        defer { window.close() }

        toolbox.refreshState()
        toolbox.layoutSubtreeIfNeeded()
        #expect(toolbox.cardCount == 3)
        #expect(toolbox.intrinsicContentSize.height > 200)
        #expect(toolbox.intrinsicContentSize.height < 520)
    }

    @Test func powerPageDynamicallyExpandsForWirelessPeripherals() {
        let suiteKey = "nearbyDevicesExpanded"
        let savedExpanded = UserDefaults.standard.object(forKey: suiteKey)
        UserDefaults.standard.set(true, forKey: suiteKey)
        defer {
            if let savedExpanded {
                UserDefaults.standard.set(savedExpanded, forKey: suiteKey)
            } else {
                UserDefaults.standard.removeObject(forKey: suiteKey)
            }
        }

        let view = PowerFlowDashboardView(snapshot: .placeholder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }

        view.layoutSubtreeIfNeeded()
        let baseHeight = view.fittingSize.height
        #expect(abs(baseHeight - 556) < 1)

        let withPeripherals = PowerFlowSnapshot(
            batteryLevel: 0.85,
            isCharging: false,
            externalConnected: true,
            chargeLimitPercent: 80,
            adapterWatts: 65,
            inputWatts: 18,
            systemWatts: 18,
            batteryWatts: 0,
            cpuWatts: 6,
            gpuWatts: 2,
            otherWatts: 10,
            temperatureCelsius: 32,
            timeToFullMinutes: nil,
            lowPowerMode: false,
            nearbyDevices: NearbyAppleDeviceBattery.placeholders,
            wirelessPeripherals: [
                WirelessPeripheralBattery(id: "bluetooth:aa", name: "Magic Mouse", symbol: "computermouse", percent: 62),
                WirelessPeripheralBattery(id: "bluetooth:bb", name: "Magic Keyboard", symbol: "keyboard", percent: 88)
            ],
            sampledAt: Date()
        )
        view.update(withPeripherals)
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.fittingSize.height - (baseHeight + 66)) < 1)
    }

    @Test func mouseBatteryCardRoutesToUnifiedPowerPage() {
        let controller = QuotaPopoverViewController()
        controller.loadViewIfNeeded()
        controller.handleMetricCardClick(.mouseBattery)
        #expect(controller.selectedPage == 3)
        controller.handleMetricCardClick(.network)
        #expect(controller.selectedPage == 7)
    }
}

@Suite(.serialized)
@MainActor
struct ToolboxPresentationTests {
    private final class Awake: PresentationKeepAwakeControlling {
        var holds = 0
        var rejectsAssertion = false
        var isPreventingSleep: Bool { holds > 0 && !rejectsAssertion }
        func beginTemporaryHold() { holds += 1 }
        func endTemporaryHold() { holds -= 1 }
    }

    @MainActor
    private final class SuspensionGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var entryContinuation: CheckedContinuation<Void, Never>?

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entryContinuation?.resume()
                entryContinuation = nil
            }
        }

        func waitUntilSuspended() async {
            guard continuation == nil else { return }
            await withCheckedContinuation { entryContinuation = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func presentationAddsAndRemovesOnlyItsOwnTemporaryHold() async {
        let awake = Awake()
        awake.holds = 1
        var visible = true
        var writes: [Bool] = []
        let controller = PresentationModeController(readDesktopVisibility: { visible }, writeDesktopVisibility: {
            writes.append($0)
            visible = $0
            return .success(())
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(controller.isActive)
        #expect(awake.holds == 2)
        #expect(!visible)
        controller.deactivate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(!controller.isActive)
        #expect(awake.holds == 1)
        #expect(visible)
        #expect(writes == [false, true])
    }

    @Test func failedActivationRequiresVerificationEvenWhenThePreferenceAlreadyMatches() async {
        let awake = Awake()
        var writes: [Bool] = []
        let controller = PresentationModeController(readDesktopVisibility: { true }, writeDesktopVisibility: { desired in
            writes.append(desired)
            return desired ? .success(()) : .failure(ToolboxOperationError(message: "模拟访达拒绝"))
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(controller.isActive)
        #expect(controller.requiresQuitRestoration)
        #expect(awake.holds == 1)
        #expect(controller.lastError == "模拟访达拒绝")
        #expect(await controller.restoreOnQuit())
        #expect(writes == [false, true])
        #expect(awake.holds == 0)
        #expect(!controller.requiresQuitRestoration)
    }

    @Test func partialActivationCannotOverwriteTheOriginalDesktopSnapshot() async {
        let awake = Awake()
        var visible = true
        var writes: [Bool] = []
        let controller = PresentationModeController(readDesktopVisibility: { visible }, writeDesktopVisibility: { desired in
            writes.append(desired)
            visible = desired
            return desired ? .success(()) : .failure(ToolboxOperationError(message: "隐藏后回滚失败"))
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(!visible)
        #expect(controller.requiresQuitRestoration)
        controller.activate(keepAwake: awake)
        #expect(writes == [false])
        #expect(awake.holds == 1)
        #expect(await controller.restoreOnQuit())
        #expect(visible)
        #expect(writes == [false, true])
        #expect(awake.holds == 0)
    }

    @Test(arguments: [false, true])
    func quitWaitsForDelayedActivationAndRestoration(activationFails: Bool) async {
        let awake = Awake()
        let activation = SuspensionGate()
        let restoration = SuspensionGate()
        var visible = true
        var writes: [Bool] = []
        let controller = PresentationModeController(readDesktopVisibility: { visible }, writeDesktopVisibility: { desired in
            writes.append(desired)
            if desired { await restoration.suspend() } else { await activation.suspend() }
            visible = desired
            return !desired && activationFails
                ? .failure(ToolboxOperationError(message: "延迟隐藏后回滚失败")) : .success(())
        })
        controller.activate(keepAwake: awake)
        await activation.waitUntilSuspended()
        var quitCompleted = false
        let quit = Task {
            let restored = await controller.restoreOnQuit()
            quitCompleted = true
            return restored
        }
        #expect(controller.isTransitioning)
        #expect(controller.requiresQuitRestoration)
        activation.resume()
        await restoration.waitUntilSuspended()
        #expect(!quitCompleted)
        #expect(!visible)
        #expect(awake.holds == 1)
        let repeatedQuit = Task { await controller.restoreOnQuit() }
        restoration.resume()
        #expect(await quit.value)
        #expect(await repeatedQuit.value)
        #expect(visible)
        #expect(awake.holds == 0)
        #expect(writes == [false, true])
        #expect(!controller.requiresQuitRestoration)
    }

    @Test func quitWaitsForAnExistingDelayedDeactivationWithoutDuplicatingWrites() async {
        let awake = Awake()
        let restoration = SuspensionGate()
        var visible = true
        var writes: [Bool] = []
        let controller = PresentationModeController(readDesktopVisibility: { visible }, writeDesktopVisibility: { desired in
            writes.append(desired)
            if desired { await restoration.suspend() }
            visible = desired
            return .success(())
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        controller.deactivate(keepAwake: awake)
        await restoration.waitUntilSuspended()
        let quit = Task { await controller.restoreOnQuit() }
        #expect(controller.requiresQuitRestoration)
        #expect(awake.holds == 1)
        restoration.resume()
        #expect(await quit.value)
        #expect(writes == [false, true])
        #expect(visible)
        #expect(awake.holds == 0)
        #expect(!controller.requiresQuitRestoration)
    }

    @Test func failedRestoreKeepsProtectionAndCanBeRetriedAtQuit() async {
        let awake = Awake()
        var visible = true
        var rejectRestore = true
        let controller = PresentationModeController(readDesktopVisibility: { visible }, writeDesktopVisibility: { desired in
            if desired && rejectRestore { return .failure(ToolboxOperationError(message: "模拟恢复失败")) }
            visible = desired
            return .success(())
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(await controller.restoreOnQuit() == false)
        #expect(controller.isActive)
        #expect(awake.holds == 1)
        #expect(controller.lastError != nil)
        rejectRestore = false
        #expect(await controller.restoreOnQuit())
        #expect(visible)
        #expect(awake.holds == 0)
        #expect(controller.lastError == nil)
    }

    @Test func quitWaitsForActivationAndRestoresAnAlreadyHiddenDesktop() async {
        let awake = Awake()
        var writes = 0
        let controller = PresentationModeController(readDesktopVisibility: { false }, writeDesktopVisibility: { _ in
            writes += 1
            return .success(())
        })
        controller.activate(keepAwake: awake)
        #expect(await controller.restoreOnQuit())
        #expect(writes == 0)
        #expect(awake.holds == 0)
        #expect(!controller.isTransitioning)
    }

    @Test func rejectedSleepAssertionDoesNotChangeDesktop() async {
        let awake = Awake()
        awake.rejectsAssertion = true
        var writes = 0
        let controller = PresentationModeController(readDesktopVisibility: { true }, writeDesktopVisibility: { _ in
            writes += 1
            return .success(())
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(!controller.isActive)
        #expect(controller.lastError != nil)
        #expect(writes == 0)
        #expect(awake.holds == 0)
    }

    @Test func privacyMaskHandlesBothIPFamiliesAndMissingAddresses() {
        #expect(PresentationModeController.maskedIP("192.168.1.9", masked: true) == "192.168.*.*")
        #expect(PresentationModeController.maskedIP("2001:db8::1", masked: true) == "已隐藏")
        #expect(PresentationModeController.maskedIP("--", masked: true) == "--")
        #expect(PresentationModeController.maskedIP("192.168.1.9", masked: false) == "192.168.1.9")
    }
}

@Suite(.serialized)
@MainActor
struct ToolboxFinderRecoveryTests {
    private typealias Helper = DesktopProductivityHelper

    private final class Awake: PresentationKeepAwakeControlling {
        var holds = 0
        var isPreventingSleep: Bool { holds > 0 }
        func beginTemporaryHold() { holds += 1 }
        func endTemporaryHold() { holds -= 1 }
    }

    @MainActor
    private final class FakeFinder {
        var isTerminated = false
        var terminatesImmediately = true
        var terminationRequests = 0

        var process: Helper.FinderProcess {
            Helper.FinderProcess(isTerminated: { [self] in isTerminated }, terminate: { [self] in
                terminationRequests += 1
                isTerminated = terminatesImmediately
                return true
            })
        }
    }

    @MainActor
    private final class Fixture {
        var preference: CFPropertyList? = kCFBooleanTrue
        var finders = [FakeFinder()]
        var writeResults: [(applies: Bool, succeeds: Bool)] = []
        var launchResults: [Bool] = []
        var createsFinderOnLaunch = true
        var writes: [Bool?] = []
        var launchCount = 0
        var visible: Bool { preference.map { CFEqual($0, kCFBooleanTrue) } ?? true }

        func writer() -> Helper.FinderPreferenceWriter {
            Helper.FinderPreferenceWriter(operations: Helper.FinderOperations(
                readPreference: { [self] _ in preference },
                writePreference: { [self] _, value in
                    writes.append(value.map { CFEqual($0, kCFBooleanTrue) })
                    let result = writeResults.isEmpty ? (applies: true, succeeds: true) : writeResults.removeFirst()
                    if result.applies { preference = value }
                    return result.succeeds
                },
                runningFinders: { [self] in finders.filter { !$0.isTerminated }.map(\.process) },
                waitForTermination: { processes in processes.allSatisfy { $0.isTerminated() } },
                openFinder: { [self] in
                    launchCount += 1
                    let succeeds = launchResults.isEmpty ? true : launchResults.removeFirst()
                    guard succeeds else { return .failure(ToolboxOperationError(message: "模拟访达重新打开失败")) }
                    if createsFinderOnLaunch { finders.append(FakeFinder()) }
                    return .success(())
                }
            ))
        }
    }

    private func expectFailure(_ result: Result<Void, ToolboxOperationError>) {
        if case .success = result { Issue.record("Recovery unexpectedly succeeded") }
    }

    private func expectSuccess(_ result: Result<Void, ToolboxOperationError>) {
        if case .failure(let error) = result { Issue.record("Unexpected recovery failure: \(error.localizedDescription)") }
    }

    @Test func partialPreferenceWriteAndFailedRollbackRemainRecoverable() async {
        let fixture = Fixture()
        fixture.writeResults = [(true, false), (false, false)]
        let writer = fixture.writer()
        let awake = Awake()
        let controller = PresentationModeController(readDesktopVisibility: { fixture.visible }, writeDesktopVisibility: {
            await writer.set("CreateDesktop", visible: $0)
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        #expect(!fixture.visible)
        #expect(controller.isActive)
        #expect(controller.requiresQuitRestoration)
        #expect(controller.lastError?.contains("原设置还原失败") == true)
        #expect(awake.holds == 1)
        #expect(fixture.launchCount == 0)
        #expect(await controller.restoreOnQuit())
        #expect(fixture.visible)
        #expect(fixture.writes == [false, true, true])
        #expect(awake.holds == 0)
        #expect(!controller.requiresQuitRestoration)
    }

    @Test func quitRetryRestartsFinderEvenWhenFailedRollbackLeavesTheDesiredPreference() async {
        let fixture = Fixture()
        fixture.launchResults = [true, false, true]
        let writer = fixture.writer()
        let awake = Awake()
        let controller = PresentationModeController(readDesktopVisibility: { fixture.visible }, writeDesktopVisibility: {
            await writer.set("CreateDesktop", visible: $0)
        })
        controller.activate(keepAwake: awake)
        await controller.waitForTransition()
        fixture.writeResults = [(true, true), (false, false)]
        #expect(await controller.restoreOnQuit() == false)
        #expect(fixture.visible)
        #expect(fixture.finders.allSatisfy { $0.isTerminated })
        #expect(writer.needsFinderRestart)
        #expect(controller.isActive)
        #expect(awake.holds == 1)
        #expect(await controller.restoreOnQuit())
        #expect(fixture.launchCount == 3)
        #expect(fixture.finders.contains { !$0.isTerminated })
        #expect(!writer.needsFinderRestart)
        #expect(!controller.requiresQuitRestoration)
        #expect(awake.holds == 0)
    }

    @Test func failedRelaunchRetainsRestartObligationAfterSuccessfulRollback() async {
        let fixture = Fixture()
        fixture.launchResults = [false, true]
        let writer = fixture.writer()
        expectFailure(await writer.set("CreateDesktop", visible: false))
        #expect(fixture.visible)
        #expect(writer.needsFinderRestart)
        #expect(fixture.finders.allSatisfy { $0.isTerminated })
        expectSuccess(await writer.set("CreateDesktop", visible: true))
        #expect(fixture.launchCount == 2)
        #expect(fixture.finders.contains { !$0.isTerminated })
        #expect(!writer.needsFinderRestart)
    }

    @Test func launchCallbackSuccessWithoutARunningFinderIsNotRecovery() async {
        let fixture = Fixture()
        fixture.createsFinderOnLaunch = false
        let writer = fixture.writer()
        expectFailure(await writer.set("CreateDesktop", visible: false))
        #expect(writer.needsFinderRestart)
        #expect(fixture.visible)
        fixture.createsFinderOnLaunch = true
        expectSuccess(await writer.set("CreateDesktop", visible: true))
        #expect(!writer.needsFinderRestart)
        #expect(fixture.launchCount == 2)
    }

    @Test func aPendingTerminationMustFinishBeforeRelaunchCanBeVerified() async {
        let fixture = Fixture()
        let finder = fixture.finders[0]
        finder.terminatesImmediately = false
        let writer = fixture.writer()
        expectFailure(await writer.set("CreateDesktop", visible: false))
        #expect(writer.needsFinderRestart)
        #expect(fixture.launchCount == 0)
        expectFailure(await writer.set("CreateDesktop", visible: true))
        #expect(finder.terminationRequests == 1)
        #expect(fixture.launchCount == 0)
        finder.isTerminated = true
        expectSuccess(await writer.set("CreateDesktop", visible: true))
        #expect(fixture.launchCount == 1)
        #expect(!writer.needsFinderRestart)
    }

    @Test func anOriginallyAbsentFinderIsNotStartedWithoutARestartObligation() async {
        let fixture = Fixture()
        fixture.finders = []
        let writer = fixture.writer()
        expectSuccess(await writer.set("CreateDesktop", visible: false))
        #expect(!fixture.visible)
        #expect(!writer.needsFinderRestart)
        #expect(fixture.launchCount == 0)
    }
}

struct ToolboxPortProtectionTests {
    private typealias Controller = ListeningPortProcessController
    private let item = ListeningPortItem(port: 3000, address: "127.0.0.1:3000", pid: 31337, processName: "node")
    private let identity = Controller.Identity(process: RunningAppIdentity(processIdentifier: 31337, startTimeSeconds: 100, startTimeMicroseconds: 1), effectiveUserID: 501, realUserID: 501, executablePath: "/opt/homebrew/bin/node")

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var signals = 0
        func nextRead() -> Int { lock.lock(); defer { lock.unlock() }; reads += 1; return reads }
        func recordSignal() { lock.lock(); defer { lock.unlock() }; signals += 1 }
        var signalCount: Int { lock.lock(); defer { lock.unlock() }; return signals }
    }

    private func operations(identityRead: @escaping @Sendable (pid_t) -> Controller.Identity?, listeners: [ListeningPortItem], calls: Calls) -> Controller.Operations {
        Controller.Operations(currentUserID: 501, protectedProcessIDs: [99], readIdentity: identityRead, readListeners: { listeners }, sendSignal: { _, signal in
            #expect(signal == SIGTERM)
            calls.recordSignal()
            return 0
        }, shouldContinue: { true })
    }

    private func expectFailure(_ result: Result<Void, ListeningPortTerminationError>, _ expected: ListeningPortTerminationError) {
        switch result {
        case .success: Issue.record("Unexpected termination request")
        case .failure(let error): #expect(error == expected)
        }
    }

    @Test func missingSnapshotIdentityCannotTerminateAnything() {
        let calls = Calls()
        let operations = operations(identityRead: { _ in identity }, listeners: [item], calls: calls)
        expectFailure(Controller.terminateSafely(.init(item: item, identity: nil), using: operations), .identityUnavailable)
        #expect(calls.signalCount == 0)
    }

    @Test func pidReusedDuringThePortRescanNeverReceivesASignal() {
        let calls = Calls()
        let changed = Controller.Identity(process: RunningAppIdentity(processIdentifier: 31337, startTimeSeconds: 101, startTimeMicroseconds: 1), effectiveUserID: 501, realUserID: 501, executablePath: identity.executablePath)
        let operations = operations(identityRead: { _ in calls.nextRead() == 1 ? identity : changed }, listeners: [item], calls: calls)
        expectFailure(Controller.terminateSafely(.init(item: item, identity: identity), using: operations), .identityChanged)
        #expect(calls.signalCount == 0)
    }

    @Test func changedListenerAddressDoesNotAuthorizeTermination() {
        let calls = Calls()
        let other = ListeningPortItem(port: 3000, address: "[::1]:3000", pid: item.pid, processName: "node")
        let operations = operations(identityRead: { _ in identity }, listeners: [other], calls: calls)
        expectFailure(Controller.terminateSafely(.init(item: item, identity: identity), using: operations), .listenerNotVerified)
        #expect(calls.signalCount == 0)
    }

    @Test func matchingIdentityAndListenerSendOnlyAGracefulTerminationRequest() {
        let calls = Calls()
        let operations = operations(identityRead: { _ in identity }, listeners: [item], calls: calls)
        let result = Controller.terminateSafely(.init(item: item, identity: identity), using: operations)
        if case .failure(let error) = result { Issue.record("Unexpected error: \(error)") }
        #expect(calls.signalCount == 1)
    }

    @Test func dashboardParentsSystemPathsAndOtherUsersAreProtected() {
        #expect(Controller.protectionError(identity: identity, currentUserID: 501, protectedProcessIDs: [31337]) == .protectedProcess)
        #expect(Controller.protectionError(identity: identity, currentUserID: 502, protectedProcessIDs: []) == .protectedProcess)
        let system = Controller.Identity(process: identity.process, effectiveUserID: 501, realUserID: 501, executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")
        #expect(Controller.protectionError(identity: system, currentUserID: 501, protectedProcessIDs: []) == .protectedProcess)
        let root = Controller.Identity(process: identity.process, effectiveUserID: 0, realUserID: 0, executablePath: identity.executablePath)
        #expect(Controller.protectionError(identity: root, currentUserID: 0, protectedProcessIDs: []) == .protectedProcess)
        let application = Controller.Identity(process: identity.process, effectiveUserID: 501, realUserID: 501, executablePath: "/Applications/Editor.app/Contents/MacOS/Editor")
        #expect(Controller.protectionError(identity: application, currentUserID: 501, protectedProcessIDs: []) == .runningApplication)
        let homebrew = Controller.Identity(process: identity.process, effectiveUserID: 501, realUserID: 501, executablePath: "/usr/local/bin/node")
        #expect(Controller.protectionError(identity: homebrew, currentUserID: 501, protectedProcessIDs: []) == nil)
    }
}
