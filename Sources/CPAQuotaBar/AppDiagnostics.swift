import AppKit
import Foundation

@MainActor
enum AppDiagnostics {
    private final class TerminationKeepAwake: PresentationKeepAwakeControlling {
        var holds = 0
        var isPreventingSleep: Bool { holds > 0 }
        func beginTemporaryHold() { holds += 1 }
        func endTemporaryHold() { holds -= 1 }
    }

    static func runTerminationCheck() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let awake = TerminationKeepAwake()
        var desktopVisible = true
        var writes: [Bool] = []
        let presentation = PresentationModeController(readDesktopVisibility: { desktopVisible }, writeDesktopVisibility: { visible in
            try? await Task.sleep(for: .milliseconds(150))
            desktopVisible = visible
            writes.append(visible)
            return .success(())
        })
        let delegate = AppDelegate(presentation: presentation, launchHandler: {
            presentation.activate(keepAwake: awake)
            app.terminate(nil)
            app.terminate(nil)
        })
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: app, queue: .main) { _ in
            MainActor.assumeIsolated {
                let passed = desktopVisible && awake.holds == 0 && !presentation.isActive && !presentation.isTransitioning && writes == [false, true]
                let report: [String: Any] = ["passed": passed, "readOnly": true, "desktopWrites": writes, "remainingHolds": awake.holds, "check": "AppKit repeated quit during asynchronous presentation activation and restoration"]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                }
                if !passed { exit(1) }
            }
        }
        app.delegate = delegate
        withExtendedLifetime((delegate, observer)) { app.run() }
    }

    static func run() async -> Int32 {
        var checks: [[String: String]] = []
        func record(_ name: String, _ status: String, _ detail: String) {
            checks.append(["name": name, "status": status, "detail": detail])
        }
        for name in ["DisplayManager", "DDCControl", "ScreenBlank", "builtin_brightness"] {
            let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name).path
            let present = executable.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
            record(name, present ? "passed" : "failed", present ? "组件已内置" : "应用内缺少组件")
        }
        let resourceNames = ["AppIcon.png", "MaShiDashboard.icns", "libimobiledevice/bin/ideviceinfo"]
        for name in resourceNames {
            let present = Bundle.module.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } ?? false
            record(name, present ? "passed" : "failed", present ? "资源可读取" : "缺少运行资源")
        }
        let monitor = SystemStatusMonitor()
        if let memory = monitor.sampleDetailedMemory(), memory.totalBytes > 0, memory.availableBytes <= memory.totalBytes {
            record("memory", "passed", "物理内存、可用量和 Swap 已读取")
        } else {
            record("memory", "failed", "无法取得有效内存样本")
        }
        let metrics = monitor.sampleMenuBarUsage(lines: [.cpu, .memory, .disk], numbers: [.network])
        record("system_metrics", metrics.isEmpty ? "failed" : "passed", "已读取 \(metrics.count) 项菜单栏指标")
        let appsMonitor = RunningAppsMonitor()
        let apps = appsMonitor.sample(appsMonitor.candidates())
        record("running_apps", apps.isEmpty ? "unavailable" : "passed", "读取到 \(apps.count) 个应用，未退出任何进程")
        let ports = await Task.detached(priority: .utility) { ListeningPortScanner.scan() }.value
        record("listening_ports", ports.isEmpty ? "unavailable" : "passed", "读取到 \(ports.count) 条监听记录，未发送终止信号")
        let audio = CoreAudioDeviceManager.shared.snapshot()
        record("audio", audio.outputs.isEmpty && audio.inputs.isEmpty ? "unavailable" : "passed", "\(audio.outputs.count) 个输出、\(audio.inputs.count) 个输入，未切换设备")
        let peripherals = PeripheralBatteryScanner.scanAll()
        record("peripheral_batteries", peripherals.isEmpty ? "unavailable" : "passed", "读取到 \(peripherals.count) 个公开电量的外设")
        if let helper = DisplayConsolePaths.helperPath("DisplayManager") {
            let result = await Task.detached(priority: .utility) { DisplayConsolePaths.runCommand(helper, ["status"], timeout: 5) }.value
            let validJSON = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) != nil
            record("display_status", result.code == 0 && validJSON ? "passed" : "failed", "仅查询显示布局，未更改分辨率或开关屏")
        }
        if DisplayConsolePaths.anyDisplayAwake(), !DisplayConsolePaths.screensPoweredOff(), let helper = DisplayConsolePaths.helperPath("DDCControl") {
            let result = await Task.detached(priority: .utility) { DisplayConsolePaths.runCommand(helper, ["get", "0x10"], timeout: 3) }.value
            record("ddc_read", result.code == 0 ? "passed" : "unavailable", result.code == 0 ? "外接屏亮度读取成功，未写入" : "当前屏幕或连接未提供可读的 DDC/CI 亮度")
        }
        let failed = checks.contains { $0["status"] == "failed" }
        let report: [String: Any] = [
            "application": AppBrand.displayName,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            "readOnly": true,
            "passed": !failed,
            "checks": checks
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return failed ? 1 : 0
    }
}
