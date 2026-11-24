import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?
    private var isPreparingToQuit = false
    private let presentation: PresentationModeController
    private let launchHandler: (() -> Void)?

    init(presentation: PresentationModeController = .shared, launchHandler: (() -> Void)? = nil) {
        self.presentation = presentation
        self.launchHandler = launchHandler
        super.init()
    }

    static func main() {
        if CommandLine.arguments.contains("--quit-self-check") {
            AppDiagnostics.runTerminationCheck()
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in exit(await AppDiagnostics.run()) }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--magpie-import-connection") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                try JSONDecoder().decode(MagpieServerConnection.self, from: data).save()
                print("服务器连接已保存到系统钥匙串。")
            } catch {
                fputs("无法保存服务器连接：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication 弱引用 delegate，需在事件循环期间保持其生命周期。
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let launchHandler {
            launchHandler()
            return
        }
        if ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DIR"] != nil {
            let appearance = ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_APPEARANCE"]
            if appearance == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            if appearance == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        }
        // 正式 App 包由 Info.plist 的 CFBundleIconFile 按需加载图标；
        // 仅在命令行裸进程调试模式下补充设置图标，避免启动时立即解码大图占用内存。
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApplication.shared.applicationIconImage = AppBrand.icon(
                size: NSSize(width: 128, height: 128)
            )
        }
        menuController = MenuController()
        if ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DIR"] == nil {
            menuController?.start()
        }
        if CommandLine.arguments.contains("--magpie-routing") || CommandLine.arguments.contains("--magpie-usage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuController?.showMagpiePage(CommandLine.arguments.contains("--magpie-usage") ? .usage : .routing)
            }
        } else if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuController?.showSettingsWindow()
            }
        } else if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if CommandLine.arguments.contains("--system-status") {
                    self?.menuController?.showSystemStatusPage()
                } else if CommandLine.arguments.contains("--power-flow") {
                    self?.menuController?.showPowerFlowPage()
                } else if CommandLine.arguments.contains("--storage-cleanup") {
                    self?.menuController?.showStorageCleanupPage()
                } else if CommandLine.arguments.contains("--displays") {
                    self?.menuController?.showDisplayConsolePage()
                } else if CommandLine.arguments.contains("--toolbox") {
                    self?.menuController?.showToolboxPage()
                } else if CommandLine.arguments.contains("--running-apps") || CommandLine.arguments.contains("--ports") {
                    self?.menuController?.showRunningAppsPage(ports: CommandLine.arguments.contains("--ports"))
                } else if CommandLine.arguments.contains("--disk-cleanup") {
                    self?.menuController?.showDiskCleanupPage()
                }
                self?.menuController?.showPopover()
                let delay = ProcessInfo.processInfo.environment["SUPER_DASHBOARD_CAPTURE_DELAY"].flatMap(Double.init) ?? 5
                DispatchQueue.main.asyncAfter(deadline: .now() + min(max(delay, 1), 60)) {
                    self?.menuController?.writeDebugFrames()
                    if CommandLine.arguments.contains("--quit-after-capture") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuController?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard presentation.requiresQuitRestoration else { return .terminateNow }
        if isPreparingToQuit { return .terminateCancel }
        isPreparingToQuit = true
        Task { @MainActor in
            let restored = await presentation.restoreOnQuit()
            if !restored {
                let alert = NSAlert()
                alert.messageText = "暂未完成演示模式还原"
                alert.informativeText = "请在工具页重试关闭演示模式，恢复桌面图标后再退出。"
                alert.runModal()
            }
            self.isPreparingToQuit = false
            if restored { sender.terminate(nil) }
        }
        return .terminateCancel
    }
}
