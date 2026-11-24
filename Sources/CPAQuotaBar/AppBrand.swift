import AppKit

enum AppBrand {
    static let displayName = "Super Dashboard"
    static let subtitle = "macOS 系统监控 · 显示器控制台 · 内存与效率中枢"

    static func icon(size: NSSize) -> NSImage {
        let image: NSImage
        if let mainIcon = Bundle.main.image(forResource: "MaShiDashboard"),
           let copy = mainIcon.copy() as? NSImage {
            image = copy
        } else if let url = Bundle.module.url(
            forResource: "AppIcon",
            withExtension: "png"
        ), let bundled = NSImage(contentsOf: url) {
            image = bundled
        } else {
            image = NSImage(
                systemSymbolName: "figure.equestrian.sports",
                accessibilityDescription: displayName
            ) ?? NSImage(size: size)
        }
        image.size = size
        return image
    }
}
