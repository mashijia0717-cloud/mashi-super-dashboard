import AppKit
import Testing
import Darwin

@main
struct AppKitTestRunner {
    @MainActor static func main() {
        guard dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_GLOBAL) != nil else {
            fatalError(String(cString: dlerror()))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Testing.__swiftPMEntryPoint() as Never
        }
        app.run()
    }
}
