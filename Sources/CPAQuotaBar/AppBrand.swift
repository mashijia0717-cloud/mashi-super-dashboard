import AppKit

enum AppBrand {
    static let displayName = "马氏超级仪表盘"

    static func icon(size: NSSize) -> NSImage {
        let image: NSImage
        if let url = Bundle.module.url(
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
