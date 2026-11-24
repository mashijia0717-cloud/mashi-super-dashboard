import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt
import RustDeskDisplayTopology

struct DisplayScreenItem: Codable, Identifiable, Equatable, Sendable {
    var id: UInt32
    var serial: UInt32
    var vendor: UInt32? = nil
    var builtin: Bool
    var virtual: Bool? = nil
    var active: Bool
    var main: Bool
    var mirror: Bool
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var hz: Double
    var x: Double
    var y: Double
    var online: Bool?
    var asleep: Bool?
    var usable: Bool?

    var isAOC: Bool { !builtin && virtual != true && (serial == 1010101 || vendor == 0x05E3) }
    var isOnline: Bool { online ?? active }
    var isReady: Bool { isOnline && (usable ?? active) && asleep != true && width > 1 && height > 1 }

    var displayTitle: String {
        builtin ? "MacBook 内置屏" : (isAOC ? "AOC AG275UXM" : "外接显示器 \(id)")
    }

    var modeSummary: String {
        guard isOnline else { return "已停用" }
        guard width > 1, height > 1 else { return "正在准备显示模式" }
        let hidpi = pixelWidth > width ? " HiDPI" : ""
        let rate = hz > 0 ? " · \(hz.formatted(.number.precision(.fractionLength(0...2)))) Hz" : ""
        return "\(width) × \(height)\(hidpi)\(rate)"
    }
}

enum DisplayConsolePaths {
    static let scriptsDir = NSHomeDirectory() + "/Library/Scripts/"
    static let alsStateDir = NSHomeDirectory() + "/Library/Application Support/als-auto-brightness/"
    static let displayPanelSupportDir = NSHomeDirectory() + "/Library/Application Support/DisplayPanel/"
    static let blankingPIDFile = displayPanelSupportDir + "blanking.pid"

    static func blankRecoveryPending() -> Bool {
        FileManager.default.fileExists(atPath: displayPanelSupportDir + "screen-sleep-state.json")
    }

    static func withBrightnessAccess(in directory: URL = URL(fileURLWithPath: displayPanelSupportDir, isDirectory: true),
                                     _ write: @Sendable () -> Bool) -> Bool {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        let descriptor = open(directory.appendingPathComponent("screen-sleep.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("screen-sleep-state.json").path),
              !screensPoweredOff(marker: directory.appendingPathComponent("blanking.pid").path) else { return false }
        return write()
    }

    static func helperPath(_ name: String) -> String? {
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundled = execDir.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }
        let legacy = "/Applications/显示器控制台.app/Contents/MacOS/\(name)"
        if FileManager.default.isExecutableFile(atPath: legacy) {
            return legacy
        }
        return nil
    }

    static func screensPoweredOff(marker: String = blankingPIDFile) -> Bool {
        guard let text = try? String(contentsOfFile: marker, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return false }
        var path = [UInt8](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return false }
        let executable = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self))
        return executable.lastPathComponent == "ScreenBlank" && kill(pid, 0) == 0
    }

    static func anyDisplayAwake() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return false }
        for i in 0..<Int(count) {
            let d = displays[i]
            let builtin = CGDisplayIsBuiltin(d) != 0
            if !RDIsVirtualDisplay(CGDisplayVendorNumber(d), CGDisplayModelNumber(d), CGDisplaySerialNumber(d), builtin),
               (builtin || !RDQuerySystemVirtualDisplay(d)),
               CGDisplayIsActive(d) != 0 && CGDisplayIsAsleep(d) == 0 {
                return true
            }
        }
        return false
    }

    static func isLegacyDisplayPanelRunning() -> Bool {
        let result = runCommand("/usr/bin/pgrep", ["-x", "DisplayPanel"], timeout: 1.5)
        return result.code == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    struct ExecResult: Sendable {
        let code: Int32
        let output: String
    }

    static func runCommand(_ path: String, _ args: [String] = [], timeout: TimeInterval = 6.0) -> ExecResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return ExecResult(code: -1, output: "缺少可执行组件：\(path)")
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = pipe

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            var data: Data {
                get { lock.withLock { storage } }
                set { lock.withLock { storage = newValue } }
            }
        }
        let box = Box()
        let group = DispatchGroup()
        let reader = pipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            group.leave()
        }
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do {
            try task.run()
        } catch {
            try? pipe.fileHandleForWriting.close()
            return ExecResult(code: -1, output: error.localizedDescription)
        }
        try? pipe.fileHandleForWriting.close()

        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            if done.wait(timeout: .now() + 0.3) == .timedOut, task.isRunning {
                kill(task.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.5)
            }
            _ = group.wait(timeout: .now() + 0.5)
            return ExecResult(code: -2, output: "命令响应超时")
        }
        _ = group.wait(timeout: .now() + 0.4)
        return ExecResult(code: task.terminationStatus, output: String(decoding: box.data, as: UTF8.self))
    }
}

enum BuiltinBrightnessBridge {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private final class Symbols: @unchecked Sendable {
        let get: GetFn?
        let set: SetFn?
        init() {
            let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
            if let handle {
                get = unsafeBitCast(dlsym(handle, "DisplayServicesGetBrightness"), to: GetFn?.self)
                set = unsafeBitCast(dlsym(handle, "DisplayServicesSetBrightness"), to: SetFn?.self)
            } else {
                get = nil
                set = nil
            }
        }
    }
    private static let symbols = Symbols()

    private static func builtinDisplayID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        for i in 0..<Int(count) {
            if CGDisplayIsBuiltin(ids[i]) != 0 && CGDisplayIsActive(ids[i]) != 0 {
                return ids[i]
            }
        }
        return nil
    }

    static func readPercent() -> Double? {
        if let id = builtinDisplayID(), let getFn = symbols.get {
            var value: Float = 0
            if getFn(id, &value) == 0, value.isFinite, (0...1).contains(value) {
                return Double(value * 100)
            }
        }
        let fallback = DisplayConsolePaths.helperPath("builtin_brightness") ?? DisplayConsolePaths.scriptsDir + "builtin_brightness"
        let res = DisplayConsolePaths.runCommand(fallback, ["get"], timeout: 2.0)
        if res.code == 0, let v = Double(res.output.trimmingCharacters(in: .whitespacesAndNewlines)), (0...1).contains(v) {
            return v * 100
        }
        return nil
    }

    static func setPercent(_ percent: Double) -> Bool {
        guard percent.isFinite, percent > 1 || DisplaySafetyPolicy.mayHideBuiltin(usableExternalCount: DisplaySafetyPolicy.usableExternalCount) else { return false }
        let clamped = Float(min(max(percent / 100.0, 0), 1))
        if clamped <= 0.01 {
            let directory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/DisplayPanel")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["brightness": (readPercent() ?? 50) / 100]).write(to: directory.appendingPathComponent("disabled-builtin.json"), options: .atomic)
            } catch { return false }
        }
        if let id = builtinDisplayID(), let setFn = symbols.set {
            if clamped <= 0.01 && DisplaySafetyPolicy.usableExternalCount == 0 { return false }
            if setFn(id, clamped) == 0 {
                if clamped <= 0.01 && DisplaySafetyPolicy.usableExternalCount == 0 {
                    _ = setFn(id, 0.5)
                    return false
                }
                return true
            }
        }
        let fallback = DisplayConsolePaths.helperPath("builtin_brightness") ?? DisplayConsolePaths.scriptsDir + "builtin_brightness"
        return DisplayConsolePaths.runCommand(fallback, ["set", String(format: "%.3f", clamped)], timeout: 2.0).code == 0
    }
}

struct HotCornerLatch: Sendable {
    var armed = false
    var enteredAt: TimeInterval?
    var dwellSeconds: TimeInterval = 0.6

    mutating func sample(inside: Bool, near: Bool, now: TimeInterval) -> Bool {
        if !near {
            armed = true
            enteredAt = nil
            return false
        }
        guard inside, armed else {
            if !inside { enteredAt = nil }
            return false
        }
        if enteredAt == nil {
            enteredAt = now
            return false
        }
        guard now - enteredAt! >= dwellSeconds else { return false }
        armed = false
        enteredAt = nil
        return true
    }
}

@MainActor
final class IntegratedHotCornerController {
    static let shared = IntegratedHotCornerController()
    static let enabledDefaultsKey = "superDashboardHotCornerEnabled"

    var onStateChanged: (() -> Void)?
    private var timer: Timer?
    private var latch = HotCornerLatch(dwellSeconds: 0.9)
    private var blankProcess: Process?
    private var appLifecycleObservers: [NSObjectProtocol] = []
    private var legacyDisplayPanelRunning = false

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            sync()
            onStateChanged?()
        }
    }

    func sync() {
        if isEnabled {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func refreshLegacyDisplayPanelState() {
        legacyDisplayPanelRunning = NSWorkspace.shared.runningApplications.contains {
            let id = $0.bundleIdentifier
            return id == "com.cindy.display-panel" || id == "com.cindy.DisplayPanel" || $0.localizedName == "显示器控制台" || $0.executableURL?.lastPathComponent == "DisplayPanel"
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        latch = HotCornerLatch(dwellSeconds: 0.9)
        refreshLegacyDisplayPanelState()
        if appLifecycleObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                appLifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLegacyDisplayPanelState() }
                })
            }
        }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.04
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        appLifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appLifecycleObservers.removeAll()
    }

    private func poll() {
        // Fast geometry check FIRST (< 1 microsecond, zero XPC / IPC calls when cursor is not in top-left corner).
        let point = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var nearAny = false
        var insideAny = false
        for screen in screens {
            let f = screen.frame
            if point.x >= f.minX && point.x <= f.minX + 20 && point.y >= f.maxY - 20 && point.y <= f.maxY {
                guard !DisplaySafetyPolicy.isManagedScreen(screen), !DisplaySafetyPolicy.isVirtualScreen(screen) else { continue }
                nearAny = true
                if point.x <= f.minX + 2 && point.y >= f.maxY - 2 {
                    insideAny = true
                }
            }
        }
        // Do not trigger while dragging or clicking the Apple menu
        if NSEvent.pressedMouseButtons != 0 {
            insideAny = false
        }
        guard latch.sample(inside: insideAny, near: nearAny, now: ProcessInfo.processInfo.systemUptime) else { return }
        guard !legacyDisplayPanelRunning else { return }
        guard !DisplayConsolePaths.screensPoweredOff(), !DisplayConsolePaths.blankRecoveryPending(), blankProcess == nil,
              let screenBlank = DisplayConsolePaths.helperPath("ScreenBlank") else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: screenBlank)
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.blankProcess = nil
                self?.onStateChanged?()
            }
        }
        if (try? task.run()) != nil {
            blankProcess = task
            onStateChanged?()
        }
    }
}
