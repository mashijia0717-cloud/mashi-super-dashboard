import AppKit
import Testing
@testable import CPAQuotaBar

private final class RecordedDisplays: @unchecked Sendable {
    struct State {
        var builtin = false
        var external = true
        var externalID: UInt32 = 3
        var foreign = false
        var virtualExternal = false
        var externalVendor: UInt32 = 0
        var asleep = false
        var usable = true
        var width = 1920
        var mirror = false
        var lidOpen = true
        var auto = false
        var externalBrightness = 44
        var builtinBrightness = 58
        var verified = true
        var permitBrightness = true
        var ddcReadable = true
        var blank: ScreenBlankState = .idle
        var ownerFinished: (@Sendable (Int32) -> Void)?
        var failStart = false
        var failRelease = false
        var owned = false
        var failStatus = false
        var holdNextStatus = false
        var statusWaiting = false
        var failLayout = false
        var failRollback = false
        var token: String?
        var expires = Date.distantPast
        var priorBuiltin = false
        var priorMirror = false
        var log: [[String]] = []
    }
    private let lock = NSLock()
    let resumeStatus = DispatchSemaphore(value: 0)
    private var state = State()

    var snapshot: State { lock.withLock { state } }
    func update(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }

    private func panel(builtin: Bool) -> [String: Any] {
        let online = builtin ? state.builtin : state.external
        var row: [String: Any] = [
            "id": builtin ? 1 : state.externalID,
            "serial": builtin ? 77 : (state.foreign ? 999 : (state.externalVendor == 0x05E3 ? 0 : 1010101)),
            "active": online, "online": online, "usable": online && state.usable && !state.asleep,
            "asleep": state.asleep, "builtin": builtin, "virtual": !builtin && state.virtualExternal,
            "main": !builtin, "mirror": state.mirror && online,
            "width": builtin ? 1440 : state.width, "height": 1080, "pixelWidth": 3840, "pixelHeight": 2160,
            "hz": 165, "x": 0, "y": 0
        ]
        if !builtin && state.externalVendor != 0 { row["vendor"] = state.externalVendor }
        return row
    }

    func command(_ path: String, _ args: [String], _ timeout: TimeInterval) -> DisplayConsolePaths.ExecResult {
        var hold = false
        let reply = lock.withLock { () -> DisplayConsolePaths.ExecResult in
            state.log.append([path] + args)
            var json: [String: Any] = ["ok": true]
            var code: Int32 = 0
            switch (path, args.first) {
            case ("DisplayManager", "status"):
                hold = state.holdNextStatus
                state.holdNextStatus = false
                if hold { state.statusWaiting = true }
                if state.failStatus { return .init(code: 1, output: "模拟枚举失败") }
                json["screens"] = [panel(builtin: true), panel(builtin: false)]
                json["preset"] = "双屏镜像"
                if let token = state.token {
                    json["pendingToken"] = token
                    json["expires"] = state.expires.timeIntervalSince1970
                }
            case ("DisplayManager", "--check-recovery"):
                json["decision"] = state.owned && (!state.external || state.virtualExternal) ? "restore-owned" : "no-owned-state"
            case ("DisplayManager", "safety-recover"):
                state.owned = false
                state.builtin = true
            case ("DisplayManager", "guarded-preset"):
                if state.failLayout { return .init(code: 1, output: "模拟切换失败") }
                state.priorBuiltin = state.builtin
                state.priorMirror = state.mirror
                state.builtin = args.last != "外接专注"
                state.mirror = args.last == "双屏镜像"
                state.token = UUID().uuidString
                state.expires = Date().addingTimeInterval(15)
                json["token"] = state.token
                json["expires"] = state.expires.timeIntervalSince1970
            case ("DisplayManager", "rollback-now"), ("DisplayManager", "confirm"):
                guard args.last == state.token else { return .init(code: 1, output: "旧凭据") }
                if args.first == "rollback-now" {
                    if state.failRollback { return .init(code: 1, output: "模拟还原失败") }
                    state.builtin = state.priorBuiltin
                    state.mirror = state.priorMirror
                }
                state.token = nil
            case ("ScreenBlank", "--status"):
                if state.blank == .unknown { return .init(code: -1, output: "") }
                json = ["active": state.blank == .active, "pendingRestore": state.blank.needsRelease]
            case ("ScreenBlank", "--release"):
                if state.failRelease { state.blank = .pendingRestore } else { state.blank = .idle }
            case ("DDCControl", "get"):
                if !state.ddcReadable { return .init(code: 1, output: "DDC 无响应") }
                json["current"] = state.externalBrightness
            case ("DDCControl", "set"):
                json["verified"] = state.verified
                if state.verified, let value = args.last.flatMap(Int.init) { state.externalBrightness = value }
            default: code = 1
            }
            return .init(code: code, output: String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        }
        if hold { _ = resumeStatus.wait(timeout: .now() + 2) }
        return reply
    }

    func environment() -> DisplayConsoleIO {
        var io = DisplayConsoleIO()
        io.helperPath = { $0 }
        io.run = command
        io.lidOpen = { self.snapshot.lidOpen }
        io.connected = {
            let state = self.snapshot
            var displays: [ConnectedDisplay] = []
            if state.builtin { displays.append(.init(id: 1, index: 1, name: "内置屏", isBuiltin: true)) }
            if state.external {
                displays.append(.init(id: state.externalID, index: 2, name: state.foreign ? "Ferry Virtual Display" : "AG275UXM", isBuiltin: false))
            }
            return displays
        }
        io.autoEnabled = { self.snapshot.auto }
        io.setAuto = { enabled in
            self.update { $0.auto = enabled; $0.log.append(["auto", String(enabled)]) }
            return enabled ? "已开启" : "已关闭"
        }
        io.brightnessAccess = { self.snapshot.permitBrightness && $0() }
        io.readBuiltin = { Double(self.snapshot.builtinBrightness) }
        io.writeBuiltin = { value in
            self.update { state in
                state.log.append(["builtin", String(Int(value))])
                if state.verified { state.builtinBrightness = Int(value) }
            }
            return true
        }
        io.startBlank = { _, finished in
            if self.snapshot.failStart { throw CocoaError(.executableNotLoadable) }
            self.update { $0.ownerFinished = finished; $0.log.append(["blank"]); $0.blank = .active }
        }
        io.openSettings = { self.update { $0.log.append(["settings"]) }; return true }
        return io
    }
}

@MainActor
private struct ScreenPage {
    enum MissingControl: Error { case button(String), layout }
    let device: RecordedDisplays
    let window: AnchoredStatusPanel
    let view: DisplayConsoleDashboardView

    init(_ initial: (inout RecordedDisplays.State) -> Void = { _ in }) {
        let hardware = RecordedDisplays()
        hardware.update(initial)
        device = hardware
        let page = DisplayConsoleDashboardView(io: hardware.environment())
        view = page
        let controller = QuotaPopoverViewController()
        controller.makeDisplayConsole = { page }
        window = AnchoredStatusPanel(contentViewController: controller)
        controller.onPreferredSizeChanged = { [weak window] in window?.resizeContent(to: $0) }
        controller.showDisplayConsolePage()
    }

    func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
    var visible: [NSView] { descendants(view).filter { !$0.isHiddenOrHasHiddenAncestor } }
    var log: [[String]] { device.snapshot.log }
    func label(_ text: String) -> Bool { visible.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(text) } }
    func button(_ title: String) throws -> NSButton {
        guard let button = visible.compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            throw MissingControl.button(title)
        }
        return button
    }
    func slider(_ name: String) throws -> NSSlider { try #require(visible.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == name }) }
    func layouts() throws -> NSSegmentedControl {
        guard let control = visible.compactMap({ $0 as? NSSegmentedControl }).first else { throw MissingControl.layout }
        return control
    }
    func press(_ control: NSControl) throws {
        try #require(control.isEnabled && !control.isHiddenOrHasHiddenAncestor)
        window.contentView?.layoutSubtreeIfNeeded()
        control.scrollToVisible(control.bounds)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()
        let center = NSPoint(x: control.bounds.midX, y: control.bounds.midY)
        let hit = root.hitTest(control.convert(center, to: root.superview))
        #expect(control.visibleRect.contains(center) && (hit === control || hit?.isDescendant(of: control) == true))
        #expect(control.sendAction(control.action, to: control.target))
    }
    func select(_ layout: ScreenPageLayout) throws {
        let control = try layouts()
        let index = try #require(ScreenPageLayout.allCases.firstIndex(of: layout))
        try #require(control.isEnabled(forSegment: index))
        control.selectedSegment = index
        try press(control)
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "等待屏幕页状态超时")
    }
    func ready() async throws { try await wait { (try? button("熄屏").isEnabled) == true } }
}

@Suite(.serialized) @MainActor
struct ScreenPageInteractionTests {
    @Test func opensActualCompactPageAndRefreshIsReadOnly() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        try await page.ready()
        #expect(try page.layouts().selectedSegment == 0)
        #expect(page.visible.compactMap { $0 as? NSSlider }.count == 1)
        #expect(page.visible.compactMap { $0 as? NSPopUpButton }.isEmpty)
        #expect(page.visible.filter { $0 is LiquidGlassCardView }.count == 3)
        #expect(page.view.fittingSize.height < 380)
        #expect(page.label("AOC AG275UXM") && page.label("165 Hz") && page.label("44%"))
        let refresh = try #require(page.visible.compactMap { $0 as? NSButton }.first { $0.toolTip == "刷新屏幕状态" })
        try page.press(refresh)
        try await page.ready()
        #expect(page.log.allSatisfy { ["status", "--status", "get"].contains($0[1]) })
        try page.press(page.button("系统显示器设置"))
        #expect(page.log.last == ["settings"])
        if ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DIR"] != nil {
            (page.window.contentViewController as? QuotaPopoverViewController)?.writeDebugFrames()
        }
    }

    @Test func allThreeLayoutsUseNativeTrialsAndCorrectConfirmationTokens() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        try await page.ready()
        for layout in [ScreenPageLayout.extended, .mirrored, .external] {
            try page.select(layout)
            try await page.wait { (try? page.button("保留").isEnabled) == true }
            let token = try #require(page.device.snapshot.token)
            #expect(page.log.contains(["DisplayManager", "guarded-preset", layout.rawValue]))
            #expect(!(try page.button("熄屏").isEnabled))
            #expect(!(try page.slider("AOC亮度").isEnabled))
            try page.press(page.button("保留"))
            try await page.ready()
            #expect(page.log.contains(["DisplayManager", "confirm", token]))
            #expect(try page.layouts().selectedSegment == ScreenPageLayout.allCases.firstIndex(of: layout))
        }
    }

    @Test func failedLayoutAndFailedRollbackRemainRetryable() async throws {
        let page = ScreenPage { $0.failLayout = true }
        defer { page.window.close() }
        try await page.ready()
        try page.select(.mirrored)
        try await page.wait { page.label("模拟切换失败") && (try? page.button("熄屏").isEnabled) == true }
        #expect(try page.layouts().selectedSegment == 0)
        page.device.update { $0.failLayout = false; $0.failRollback = true }
        try page.select(.extended)
        try await page.wait { (try? page.button("还原").isEnabled) == true }
        let token = try #require(page.device.snapshot.token)
        try page.press(page.button("还原"))
        try await page.wait { page.label("模拟还原失败") && (try? page.button("还原").isEnabled) == true }
        page.device.update { $0.failRollback = false }
        try page.press(page.button("还原"))
        try await page.ready()
        #expect(page.log.filter { $0 == ["DisplayManager", "rollback-now", token] }.count == 2)
        #expect(try page.layouts().selectedSegment == 0)
    }

    @Test func adoptsExistingDeadlineAndRejectsAnotherWindowsToken() async throws {
        let page = ScreenPage { $0.token = "earlier"; $0.expires = Date().addingTimeInterval(10) }
        defer { page.window.close() }
        try await page.wait { (try? page.button("保留").isEnabled) == true }
        page.device.update { $0.token = "replacement"; $0.expires = Date().addingTimeInterval(-1) }
        try page.press(page.button("保留"))
        try await page.wait { page.label("确认已到期") && (try? page.button("还原").isEnabled) == true }
        #expect(!page.log.contains { $0.contains("confirm") })
        #expect(!(try page.button("保留").isEnabled))
        page.device.update { $0.token = nil }
        try await page.ready()
        #expect(!page.label("确认已到期"))
    }

    @Test func builtinOnlyAndForeignOrSleepingScreensDoNotOfferAOCWrites() async throws {
        let page = ScreenPage { $0.external = false; $0.builtin = true }
        defer { page.window.close() }
        try await page.ready()
        #expect(page.visible.compactMap { $0 as? NSSegmentedControl }.isEmpty)
        #expect(page.visible.compactMap { $0 as? NSSlider }.count == 1)
        #expect(!page.log.contains { $0.first == "DDCControl" })
        page.device.update { $0.external = true; $0.foreign = true }
        page.view.topologyChanged()
        try await page.wait { page.label("Ferry Virtual Display") }
        #expect(!page.visible.compactMap { $0 as? NSButton }.contains { $0.title == "熄屏" })
        page.device.update { $0.foreign = false; $0.asleep = true }
        page.view.topologyChanged()
        try await page.wait { page.label("休眠中") }
        #expect(!(try page.layouts().isEnabled(forSegment: 0)))
        #expect(!page.log.contains { $0.first == "DDCControl" })
    }

    @Test func disconnectedOrReplacedTargetCannotReceiveAnOldAction() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        try await page.ready()
        page.device.update { $0.externalID = 99 }
        let slider = try page.slider("AOC亮度")
        slider.integerValue = 65
        try page.press(slider)
        try await page.wait { page.label("亮度未能确认") && slider.isEnabled }
        #expect(!page.log.contains { $0.contains("set") })
        page.device.update { $0.external = false; $0.builtin = true }
        try page.select(.extended)
        try await page.wait { page.label("重新选择布局") }
        #expect(!page.log.contains { $0.contains("guarded-preset") })
    }

    @Test func staleRefreshCannotRestoreActionsForADisconnectedScreen() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        try await page.ready()
        let slider = try page.slider("AOC亮度")
        page.device.update { $0.holdNextStatus = true }
        page.view.refreshAll()
        try await page.wait { page.device.snapshot.statusWaiting }
        page.device.update { $0.external = false; $0.builtin = true }
        page.view.topologyChanged()
        _ = slider.sendAction(slider.action, to: slider.target)
        page.device.resumeStatus.signal()
        try await page.ready()
        #expect(page.label("MacBook 内置屏"))
        #expect(page.visible.compactMap { $0 as? NSSlider }.count == 1)
        #expect(slider.isHiddenOrHasHiddenAncestor && !slider.isEnabled)
        #expect(!page.log.contains { $0.contains("set") })
    }

    @Test func presentedOffscreenPageTracksPhysicalChangesWithoutReopening() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        let controller = try #require(page.window.contentViewController as? QuotaPopoverViewController)
        controller.setPopoverVisible(true)
        try await page.ready()
        #expect(!page.window.isVisible)
        page.device.update { $0.foreign = true }
        page.view.physicalChanged()
        try await page.wait { page.label("Ferry Virtual Display") }
        #expect(page.visible.filter { $0 is LiquidGlassCardView }.count == 1)
        #expect(controller.preferredContentSize.height < 220)
        #expect(!page.log.contains { $0.contains("set") || $0.contains("safety-recover") })
    }

    @Test func unknownBlankStateBlocksWritesAndOldNativeExitCannotEndNewRequest() async throws {
        let page = ScreenPage { $0.blank = .unknown }
        defer { page.window.close() }
        try await page.wait { page.label("状态未知") }
        #expect(!(try page.button("熄屏").isEnabled))
        #expect(!page.log.contains { $0.first == "DDCControl" })
        page.device.update { $0.blank = .idle }
        page.view.refreshAll()
        try await page.ready()
        try page.press(page.button("熄屏"))
        try await page.wait { (try? page.button("恢复背光").isEnabled) == true }
        let oldExit = try #require(page.device.snapshot.ownerFinished)
        try page.press(page.button("恢复背光"))
        try await page.ready()
        try page.press(page.button("熄屏"))
        try await page.wait { (try? page.button("恢复背光").isEnabled) == true }
        oldExit(1)
        await Task.yield()
        #expect(!page.label("硬件熄屏未完成"))
        #expect(page.device.snapshot.blank == .active)
        #expect(page.log.filter { $0 == ["blank"] }.count == 2)
    }

    @Test func manualBrightnessRequiresVerifiedHardwareAndIndependentTargets() async throws {
        let page = ScreenPage { $0.builtin = true }
        defer { page.window.close() }
        try await page.ready()
        let external = try page.slider("AOC亮度")
        let builtin = try page.slider("内置屏亮度")
        external.integerValue = 65
        try page.press(external)
        try await page.wait { page.label("65%") && external.isEnabled }
        #expect(page.log.contains(["DDCControl", "set", "0x10", "65"]))
        builtin.integerValue = 33
        try page.press(builtin)
        try await page.wait { page.label("33%") && builtin.isEnabled }
        #expect(page.log.contains(["builtin", "33"]))
        page.device.update { $0.verified = false }
        external.integerValue = 77
        try page.press(external)
        try await page.wait { page.label("亮度未能确认") && external.isEnabled }
        #expect(external.integerValue == 65 && page.label("65%"))
        page.device.update { $0.permitBrightness = false }
        builtin.integerValue = 8
        try page.press(builtin)
        try await page.wait { builtin.isEnabled && builtin.integerValue == 33 }
        #expect(!page.log.contains(["builtin", "8"]))
        #expect(builtin.minValue > 1)
    }

    @Test func automaticBrightnessExcludesManualExternalWritesAndAllowsTurningItOff() async throws {
        let page = ScreenPage { $0.builtin = true; $0.auto = true }
        defer { page.window.close() }
        try await page.ready()
        let automatic = try #require(page.visible.compactMap { $0 as? NSSwitch }.first)
        let external = try page.slider("AOC亮度")
        #expect(!external.isEnabled)
        #expect((try page.slider("内置屏亮度")).isEnabled)
        automatic.state = .off
        try page.press(automatic)
        try await page.wait { external.isEnabled && page.log.contains(["auto", "false"]) }
        automatic.state = .on
        try page.press(automatic)
        try await page.wait { automatic.isEnabled && !external.isEnabled && page.log.contains(["auto", "true"]) }
        page.device.update { $0.ddcReadable = false }
        page.view.refreshAll()
        try await page.wait { page.label("不可读") && automatic.isEnabled }
        automatic.state = .off
        try page.press(automatic)
        try await page.wait { !page.device.snapshot.auto && !automatic.isEnabled }
    }

    @Test func nativeBlankStartsOnceAndRecoveryFailureKeepsTheRestoreAction() async throws {
        let page = ScreenPage()
        defer { page.window.close() }
        try await page.ready()
        let power = try page.button("熄屏")
        try page.press(power)
        _ = power.sendAction(power.action, to: power.target)
        try await page.wait { (try? page.button("恢复背光").isEnabled) == true }
        #expect(page.log.filter { $0 == ["blank"] }.count == 1)
        #expect(page.visible.compactMap { $0 as? NSSlider }.isEmpty)
        page.device.update { $0.failRelease = true }
        try page.press(power)
        try await page.wait { page.label("背光尚未确认") && power.isEnabled }
        page.device.update { $0.failRelease = false }
        try page.press(power)
        page.device.snapshot.ownerFinished?(0)
        try await page.ready()
        #expect(page.log.filter { $0 == ["ScreenBlank", "--release"] }.count == 2)
    }

    @Test func orphanRecoverySurvivesEnumerationFailureAndStaleReleaseNeverBlanks() async throws {
        let page = ScreenPage { $0.blank = .pendingRestore; $0.failStatus = true }
        defer { page.window.close() }
        try await page.wait { (try? page.button("恢复背光").isEnabled) == true }
        #expect(page.label("模拟枚举失败"))
        #expect(!page.log.contains { $0.first == "DDCControl" })
        try page.press(page.button("系统显示器设置"))
        page.device.update { $0.blank = .idle; $0.failStatus = false }
        try page.press(page.button("恢复背光"))
        try await page.ready()
        #expect(!page.log.contains(["blank"]) && !page.log.contains(["ScreenBlank", "--release"]))
    }

    @Test func recoverBuiltinUsesOnlyOwnedStateAndRechecksWhenAOCReconnects() async throws {
        let page = ScreenPage { $0.external = false; $0.owned = true }
        defer { page.window.close() }
        try await page.wait { (try? page.button("恢复内置屏").isEnabled) == true }
        page.device.update { $0.external = true }
        try page.press(page.button("恢复内置屏"))
        try await page.ready()
        #expect(!page.log.contains(["DisplayManager", "safety-recover"]))
        page.device.update { $0.external = false }
        page.view.topologyChanged()
        try await page.wait { (try? page.button("恢复内置屏").isEnabled) == true }
        try page.press(page.button("恢复内置屏"))
        try await page.ready()
        #expect(page.log.contains(["DisplayManager", "safety-recover"]))
        #expect(!page.log.contains { $0.contains("recover-builtin") })
        #expect(!page.visible.compactMap { $0 as? NSButton }.contains { $0.title == "恢复内置屏" })
    }

    @Test func unreadyModeAndClosedLidBlockUnsafeCommandsAndLaunchErrorsAreVisible() async throws {
        let page = ScreenPage { $0.width = 1 }
        defer { page.window.close() }
        try await page.wait { page.label("AOC AG275UXM") }
        #expect(!(try page.layouts().isEnabled(forSegment: 0)))
        #expect(!(try page.button("熄屏").isEnabled))
        page.device.update { $0.width = 1920; $0.lidOpen = false }
        page.view.topologyChanged()
        try await page.wait { (try? page.layouts().isEnabled(forSegment: 0)) == true }
        #expect(!(try page.layouts().isEnabled(forSegment: 1)))
        #expect(!(try page.button("熄屏").isEnabled))
        page.device.update { $0.lidOpen = true; $0.failStart = true }
        page.view.topologyChanged()
        try await page.ready()
        try page.press(page.button("熄屏"))
        try await page.wait { page.label("熄屏未启动") && (try? page.button("熄屏").isEnabled) == true }
    }

    @Test func ferryVirtualDisplayStillOffersBuiltinRecoveryAndHDMIModelsMatchVendor() async throws {
        let page = ScreenPage { $0.builtin = false; $0.external = true; $0.foreign = true; $0.virtualExternal = true; $0.owned = true }
        defer { page.window.close() }
        try await page.wait { (try? page.button("恢复内置屏").isEnabled) == true }
        #expect(page.label("Ferry Virtual Display"))
        try page.press(page.button("恢复内置屏"))
        try await page.wait { page.label("MacBook 内置屏") }
        #expect(page.log.contains(["DisplayManager", "safety-recover"]))

        // AOC over HDMI where EDID serial reports 0 but vendor is 0x05E3 (1507)
        page.device.update { $0.foreign = false; $0.virtualExternal = false; $0.externalVendor = 0x05E3 }
        page.view.topologyChanged()
        try await page.ready()
        #expect(page.label("AOC AG275UXM"))
        #expect((try? page.layouts().isEnabled(forSegment: 0)) == true)
    }
}
