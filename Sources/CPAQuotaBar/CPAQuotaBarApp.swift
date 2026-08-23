import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppBrand.icon(
            size: NSSize(width: 512, height: 512)
        )
        menuController = MenuController()
        menuController?.start()
        if CommandLine.arguments.contains("--settings") {
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
                }
                self?.menuController?.showPopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.menuController?.writeDebugFrames()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuController?.stop()
    }
}
