import AppKit
import Foundation

// MARK: - Storage cleanup model

/// 一个可以安全移入废纸篓的清理对象。清理范围始终限制在当前用户目录内，
/// 不使用 sudo，也不直接执行 shell 删除命令。
struct StorageCleanupItem: Hashable, Identifiable, Sendable {
    let id: String
    let categoryID: String
    let path: String
    let name: String
    let bytes: Int64
    let isDirectory: Bool
}

struct StorageCleanupCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let items: [StorageCleanupItem]

    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

struct StorageCleanupSnapshot: Sendable {
    let categories: [StorageCleanupCategory]
    let scannedAt: Date

    var bytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }
}

struct StorageCleanupResult: Sendable {
    let removedCount: Int
    let reclaimedBytes: Int64
    let skippedCount: Int
    let errors: [String]
}

private struct StorageCleanupTarget: Sendable {
    let categoryID: String
    let path: String
    let mode: Mode

    enum Mode: Sendable {
        case directChildren
        case matchingSuffixes([String])
    }
}

/// 受 Mole 的 clean/analyze 设计启发的本机清理器。
///
/// 这里刻意只实现“可重建缓存、日志、开发产物和未完成下载”这类低风险目标，
/// 并把对象移入 macOS 废纸篓，避免第三方应用拥有永久删除权限。
enum StorageCleanupService {
    private static let maxItems = 5_000
    private static let maxTraversalFiles = 250_000

    static func scan(
        runningBundleIdentifiers: Set<String> = [],
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) -> StorageCleanupSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homePath = home.path
        let targets = makeTargets(homePath: homePath)
        var categories: [String: (title: String, subtitle: String, symbol: String, items: [StorageCleanupItem])] = [
            "userCaches": ("应用缓存", "~/Library/Caches 中可重建的缓存", "shippingbox.fill", []),
            "browserCaches": ("浏览器缓存", "Safari、Chrome、Edge、Firefox 等缓存", "safari.fill", []),
            "developerCaches": ("开发工具缓存", "Xcode DerivedData、模拟器和包管理器缓存", "hammer.fill", []),
            "logs": ("日志与诊断", "旧的应用日志和崩溃报告", "doc.text.magnifyingglass", []),
            "downloads": ("未完成下载", "Downloads 中未完成的临时下载文件", "arrow.down.circle.fill", [])
        ]
        var seen = Set<String>()
        var traversalBudget = maxTraversalFiles

        for target in targets {
            guard !targetIsActive(target.path, runningBundleIdentifiers: runningBundleIdentifiers) else { continue }
            guard let root = safeURL(path: target.path, homePath: homePath) else { continue }
            let urls = matchingURLs(root: root, mode: target.mode)
            let measuredSizes = measureSizes(of: urls)
            for url in urls {
                if !shouldContinue() { break }
                if target.categoryID == "userCaches",
                   genericCacheExclusions.contains(url.lastPathComponent) {
                    continue
                }
                if target.categoryID == "userCaches",
                   runningBundleIdentifiers.contains(url.lastPathComponent) {
                    continue
                }
                guard seen.insert(url.path).inserted else { continue }
                guard let item = makeItem(
                    url: url,
                    categoryID: target.categoryID,
                    homePath: homePath,
                    measuredBytes: measuredSizes[url.path],
                    shouldContinue: shouldContinue,
                    traversalBudget: &traversalBudget
                ) else { continue }
                guard item.bytes > 0 else { continue }
                guard categories[target.categoryID] != nil else { continue }
                guard categories[target.categoryID]!.items.count < maxItems else { continue }
                categories[target.categoryID]!.items.append(item)
            }
        }

        let output = categories.compactMap { key, value -> StorageCleanupCategory? in
            guard !value.items.isEmpty else { return nil }
            return StorageCleanupCategory(
                id: key,
                title: value.title,
                subtitle: value.subtitle,
                symbol: value.symbol,
                items: value.items.sorted { $0.bytes > $1.bytes }
            )
        }
        .sorted { $0.bytes > $1.bytes }
        return StorageCleanupSnapshot(categories: output, scannedAt: Date())
    }

    static func remove(
        items: [StorageCleanupItem],
        runningBundleIdentifiers: Set<String> = [],
        shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled }
    ) -> StorageCleanupResult {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let fileManager = FileManager.default
        var removedCount = 0
        var reclaimedBytes: Int64 = 0
        var skippedCount = 0
        var errors: [String] = []
        var paths = Set<String>()

        // 若同时选中了目录和目录内的项目，只处理目录，避免重复移动。
        let sorted = items.sorted { $0.path.count < $1.path.count }
        for item in sorted {
            if !shouldContinue() { break }
            guard paths.insert(item.path).inserted else { continue }
            guard isSafePath(item.path, homePath: homePath) else {
                skippedCount += 1
                continue
            }
            if isItemActive(item, runningBundleIdentifiers: runningBundleIdentifiers) {
                skippedCount += 1
                continue
            }
            if paths.contains(where: { item.path.hasPrefix($0 + "/") }) {
                skippedCount += 1
                continue
            }
            let url = URL(fileURLWithPath: item.path, isDirectory: item.isDirectory)
            guard fileManager.fileExists(atPath: item.path) else {
                skippedCount += 1
                continue
            }
            // 只移入废纸篓；失败时不降级为永久删除。
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                removedCount += 1
                reclaimedBytes += item.bytes
            } catch {
                errors.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        return StorageCleanupResult(
            removedCount: removedCount,
            reclaimedBytes: reclaimedBytes,
            skippedCount: skippedCount,
            errors: Array(errors.prefix(8))
        )
    }

    private static func makeTargets(homePath: String) -> [StorageCleanupTarget] {
        func path(_ components: String...) -> String {
            components.reduce(homePath) { URL(fileURLWithPath: $0).appendingPathComponent($1).path }
        }

        // 这些目标均来自 Mole 的用户级 clean 目标；不会触碰系统目录、应用本体、
        // 文档、照片、项目源文件、虚拟机镜像或账号数据。
        return [
            StorageCleanupTarget(categoryID: "userCaches", path: path("Library", "Caches"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "browserCaches", path: path("Library", "Caches", "com.apple.Safari"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "browserCaches", path: path("Library", "Caches", "Google", "Chrome"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "browserCaches", path: path("Library", "Caches", "com.microsoft.edgemac"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "browserCaches", path: path("Library", "Caches", "org.mozilla.firefox"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "browserCaches", path: path("Library", "Caches", "BraveSoftware", "Brave-Browser"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path("Library", "Developer", "Xcode", "DerivedData"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path("Library", "Developer", "CoreSimulator", "Caches"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path(".npm", "_cacache"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path(".cache", "pip"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path(".cache", "yarn"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path(".gradle", "caches"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path(".cargo", "registry", "cache"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "developerCaches", path: path("Library", "Caches", "Homebrew"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "logs", path: path("Library", "Logs"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "logs", path: path("Library", "DiagnosticReports"), mode: .directChildren),
            StorageCleanupTarget(categoryID: "downloads", path: path("Downloads"), mode: .matchingSuffixes([".download", ".crdownload", ".part", ".tmp"]))
        ]
    }

    private static let genericCacheExclusions: Set<String> = [
        "Google", "BraveSoftware", "com.apple.Safari", "com.microsoft.edgemac",
        "org.mozilla.firefox", "Homebrew", "Code", "CocoaPods", "Chromium"
    ]

    private static func targetIsActive(
        _ path: String,
        runningBundleIdentifiers: Set<String>
    ) -> Bool {
        let blocked: [(String, String)] = [
            ("/Library/Caches/com.apple.Safari", "com.apple.Safari"),
            ("/Library/Caches/Google/Chrome", "com.google.Chrome"),
            ("/Library/Caches/com.microsoft.edgemac", "com.microsoft.edgemac"),
            ("/Library/Caches/org.mozilla.firefox", "org.mozilla.firefox"),
            ("/Library/Caches/BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("/Library/Developer/Xcode/DerivedData", "com.apple.dt.Xcode"),
            ("/Library/Developer/CoreSimulator/Caches", "com.apple.dt.Xcode")
        ]
        return blocked.contains { suffix, bundleID in
            path.hasSuffix(suffix) && runningBundleIdentifiers.contains(bundleID)
        }
    }

    private static func isItemActive(
        _ item: StorageCleanupItem,
        runningBundleIdentifiers: Set<String>
    ) -> Bool {
        if item.categoryID == "userCaches" {
            return runningBundleIdentifiers.contains(item.name)
        }
        if item.categoryID == "browserCaches" {
            return !runningBundleIdentifiers.isDisjoint(with: [
                "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
                "org.mozilla.firefox", "com.brave.Browser"
            ])
        }
        if item.path.contains("/Library/Developer/Xcode/DerivedData/") ||
            item.path.contains("/Library/Developer/CoreSimulator/Caches/") {
            return runningBundleIdentifiers.contains("com.apple.dt.Xcode")
        }
        return false
    }

    private static func matchingURLs(root: URL, mode: StorageCleanupTarget.Mode) -> [URL] {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return [] }
        switch mode {
        case .directChildren:
            return urls
        case let .matchingSuffixes(suffixes):
            return urls.filter { url in suffixes.contains { url.lastPathComponent.lowercased().hasSuffix($0) } }
        }
    }

    private static func makeItem(
        url: URL,
        categoryID: String,
        homePath: String,
        measuredBytes: Int64?,
        shouldContinue: @escaping @Sendable () -> Bool,
        traversalBudget: inout Int
    ) -> StorageCleanupItem? {
        guard isSafePath(url.path, homePath: homePath) else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { return nil }
        let isDirectory = values?.isDirectory == true
        let bytes = measuredBytes ?? size(of: url, isDirectory: isDirectory, shouldContinue: shouldContinue, traversalBudget: &traversalBudget)
        return StorageCleanupItem(
            id: url.path,
            categoryID: categoryID,
            path: url.path,
            name: url.lastPathComponent,
            bytes: bytes,
            isDirectory: isDirectory
        )
    }

    /// BSD du 一次接收一批路径，比 Swift 逐文件遍历缓存目录快很多；失败时由
    /// makeItem 回退到受预算限制的 FileManager 枚举。
    private static func measureSizes(of urls: [URL]) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk"] + urls.map(\.path)
        process.environment = ["LC_ALL": "C", "LANG": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [:] }
            var result: [String: Int64] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(
                    maxSplits: 1,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0 == " " || $0 == "\t" }
                )
                guard parts.count == 2, let kilobytes = Int64(parts[0]) else { continue }
                let path = String(parts[1])
                result[path] = max(0, kilobytes) * 1024
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func size(
        of url: URL,
        isDirectory: Bool,
        shouldContinue: @escaping @Sendable () -> Bool,
        traversalBudget: inout Int
    ) -> Int64 {
        if !isDirectory {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        guard traversalBudget > 0 else { return 0 }
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        for case let child as URL in enumerator {
            if !shouldContinue() { break }
            traversalBudget -= 1
            guard traversalBudget >= 0 else { break }
            let values = try? child.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private static func safeURL(path: String, homePath: String) -> URL? {
        guard FileManager.default.fileExists(atPath: path), isSafePath(path, homePath: homePath) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func isSafePath(_ path: String, homePath: String) -> Bool {
        let normalizedHome = URL(fileURLWithPath: homePath).standardizedFileURL.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized.hasPrefix(normalizedHome + "/") else { return false }
        guard !normalized.contains("/../"), !normalized.hasSuffix("/..") else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(normalizedHome + "/")
    }
}

// MARK: - Cleanup page

@MainActor
final class StorageCleanupCategoryRow: LiquidGlassCardView {
    let category: StorageCleanupCategory
    var onSelectionChanged: ((Bool) -> Void)?
    var onExpansionChanged: ((Bool) -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let disclosureButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var expanded = false

    init(category: StorageCleanupCategory) {
        self.category = category
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 64).isActive = true
        checkbox.target = self
        checkbox.action = #selector(selectionChanged)
        checkbox.allowsMixedState = true
        checkbox.setAccessibilityLabel("选择清理\(category.title)")
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        disclosureButton.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "展开\(category.title)"
        )
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.bezelStyle = .inline
        disclosureButton.isBordered = false
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpansion)
        disclosureButton.setAccessibilityLabel("展开\(category.title)明细")
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureButton)

        let image = NSImageView(image: NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .systemBlue
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)

        titleLabel.stringValue = category.title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.stringValue = "\(formatBytes(category.bytes)) · \(category.items.count) 项"
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 22),
            checkbox.heightAnchor.constraint(equalToConstant: 22),
            image.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22),
            image.heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -8),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            disclosureButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(equalToConstant: 24),
            disclosureButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelectionState(_ state: NSControl.StateValue) {
        checkbox.state = state
        switch state {
        case .on:
            checkbox.setAccessibilityValue("全部选择")
        case .mixed:
            checkbox.setAccessibilityValue("部分选择")
        default:
            checkbox.setAccessibilityValue("未选择")
        }
    }

    func setExpanded(_ isExpanded: Bool) {
        expanded = isExpanded
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        disclosureButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isExpanded ? "收起\(category.title)" : "展开\(category.title)"
        )
        disclosureButton.setAccessibilityLabel("\(isExpanded ? "收起" : "展开")\(category.title)明细")
    }

    @objc private func selectionChanged() {
        onSelectionChanged?(checkbox.state == .on)
    }

    @objc private func toggleExpansion() {
        onExpansionChanged?(!expanded)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if checkbox.frame.contains(point) { return checkbox }
        if disclosureButton.frame.contains(point) { return disclosureButton }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onExpansionChanged?(!expanded)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class StorageCleanupItemRowView: NSView {
    let item: StorageCleanupItem
    var onSelectionChanged: ((Bool) -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var selected: Bool

    init(item: StorageCleanupItem, selected: Bool) {
        self.item = item
        self.selected = selected
        super.init(frame: .zero)
        let presentation = itemPresentation(for: item)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 10
        applyRowFill()
        toolTip = item.path

        checkbox.state = selected ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(selectionChanged)
        checkbox.setAccessibilityLabel("选择清理\(presentation.name)")
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        let icon = NSImageView(image: presentation.icon)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let nameLabel = NSTextField(labelWithString: presentation.name)
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.toolTip = item.path
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let pathLabel = NSTextField(labelWithString: item.name)
        pathLabel.font = .systemFont(ofSize: 9.5)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = item.path
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        let sizeLabel = NSTextField(labelWithString: formatBytes(item.bytes))
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 22),
            checkbox.heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRowFill()
    }

    private func applyRowFill() {
        var fill = NSColor.labelColor.withAlphaComponent(0.028).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor.labelColor.withAlphaComponent(0.028).cgColor
        }
        layer?.backgroundColor = fill
    }

    @objc private func selectionChanged() {
        selected = checkbox.state == .on
        onSelectionChanged?(selected)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        checkbox.frame.contains(point) ? checkbox : self
    }

    override func mouseDown(with event: NSEvent) {
        selected.toggle()
        checkbox.state = selected ? .on : .off
        onSelectionChanged?(selected)
    }

    private func itemPresentation(for item: StorageCleanupItem) -> (name: String, icon: NSImage) {
        if item.categoryID == "userCaches",
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.name) {
            let bundle = Bundle(url: applicationURL)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? applicationURL.deletingPathExtension().lastPathComponent
            return (name, NSWorkspace.shared.icon(forFile: applicationURL.path))
        }
        let icon = NSImage(
            systemSymbolName: "folder.fill",
            accessibilityDescription: nil
        ) ?? NSImage()
        return (item.name, icon)
    }
}

@MainActor
final class StorageCleanupDashboardView: NSView {
    var onScan: (() -> Void)?
    var onClean: (([StorageCleanupItem]) -> Void)?
    var onHeightChanged: (() -> Void)?

    private let stack = NSStackView()
    private let summaryLabel = NSTextField(labelWithString: "—")
    private let detailLabel = NSTextField(labelWithString: "准备扫描可重建文件")
    private let scanButton = NSButton()
    private let cleanButton = NSButton(title: "清理所选", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let rowsStack = NSStackView()
    private var categoryRows: [String: StorageCleanupCategoryRow] = [:]
    private var expandedCategoryIDs = Set<String>()
    private var selectedItemIDs = Set<String>()
    private var currentSnapshot: StorageCleanupSnapshot?
    var snapshot: StorageCleanupSnapshot? { currentSnapshot }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let categories = currentSnapshot?.categories ?? []
        let itemCount = categories
            .filter { expandedCategoryIDs.contains($0.id) }
            .reduce(0) { $0 + $1.items.count }
        let visibleRowCount = categories.count + itemCount
        let rowHeight = CGFloat(categories.count * 64 + itemCount * 44 + max(0, visibleRowCount - 1) * 7)
        // summary + toolbar + rows + explanatory note + stack spacing/insets
        return NSSize(width: 376, height: 108 + 30 + rowHeight + 34 + 32)
    }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let summaryCard = LiquidGlassCardView()
        summaryCard.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.heightAnchor.constraint(equalToConstant: 108).isActive = true
        let caption = NSTextField(labelWithString: "可释放空间")
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.addSubview(caption)
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.addSubview(summaryLabel)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 14),
            caption.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 3)
        ])
        stack.addArrangedSubview(summaryCard)
        summaryCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        scanButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新扫描")
        scanButton.imagePosition = .imageOnly
        scanButton.bezelStyle = .inline
        if #available(macOS 26.0, *) {
            scanButton.bezelStyle = .glass
        }
        scanButton.toolTip = "重新扫描储存空间"
        scanButton.setAccessibilityLabel("重新扫描储存空间")
        scanButton.target = self
        scanButton.action = #selector(scan)
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(scanButton)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(progress)
        cleanButton.bezelStyle = .rounded
        if #available(macOS 26.0, *) {
            cleanButton.bezelStyle = .glass
        }
        cleanButton.controlSize = .small
        cleanButton.isEnabled = false
        cleanButton.target = self
        cleanButton.action = #selector(clean)
        cleanButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(cleanButton)
        NSLayoutConstraint.activate([
            scanButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 4),
            scanButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            scanButton.widthAnchor.constraint(equalToConstant: 28),
            scanButton.heightAnchor.constraint(equalToConstant: 28),
            progress.leadingAnchor.constraint(equalTo: scanButton.trailingAnchor, constant: 6),
            progress.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            cleanButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -4),
            cleanButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            cleanButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        stack.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 7
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let note = NSTextField(wrappingLabelWithString: "仅清理可重建缓存、日志和未完成下载；选中后会先移入废纸篓，不触碰文档、照片或项目源文件。")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        note.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(note)
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 弹窗内容区为 400pt，accountStack 两侧各留 12pt；固定内容宽度
            // 避免 NSStackView 在 fittingSize 阶段把页面压缩到右侧窄列。
            widthAnchor.constraint(equalToConstant: 376)
        ])
    }

    func setScanning(_ scanning: Bool) {
        progress.isHidden = !scanning
        if scanning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        scanButton.isEnabled = !scanning
        cleanButton.isEnabled = !scanning && !selectedItemIDs.isEmpty
        if scanning { detailLabel.stringValue = "正在扫描本机可重建文件…" }
        invalidateIntrinsicContentSize()
    }

    func apply(snapshot: StorageCleanupSnapshot, message: String? = nil) {
        currentSnapshot = snapshot
        let validItemIDs = Set(snapshot.categories.flatMap(\.items).map(\.id))
        let validCategoryIDs = Set(snapshot.categories.map(\.id))
        selectedItemIDs.formIntersection(validItemIDs)
        expandedCategoryIDs.formIntersection(validCategoryIDs)
        categoryRows.removeAll()
        for category in snapshot.categories {
            let row = StorageCleanupCategoryRow(category: category)
            row.onSelectionChanged = { [weak self] selected in
                self?.setCategory(category.id, selected: selected)
            }
            row.onExpansionChanged = { [weak self] expanded in
                self?.setCategory(category.id, expanded: expanded)
            }
            categoryRows[category.id] = row
        }
        rebuildVisibleRows()
        summaryLabel.stringValue = formatBytes(snapshot.bytes)
        detailLabel.stringValue = message ?? "发现 \(snapshot.itemCount) 项 · 扫描于 \(snapshot.scannedAt.formatted(date: .omitted, time: .shortened))"
        selectionChanged()
        invalidateIntrinsicContentSize()
    }

    func showMessage(_ message: String) {
        detailLabel.stringValue = message
    }

    private func selectedItems() -> [StorageCleanupItem] {
        (currentSnapshot?.categories ?? [])
            .flatMap(\.items)
            .filter { selectedItemIDs.contains($0.id) }
    }

    private func setCategory(_ categoryID: String, selected: Bool) {
        guard let category = currentSnapshot?.categories.first(where: { $0.id == categoryID }) else { return }
        let itemIDs = Set(category.items.map(\.id))
        if selected {
            selectedItemIDs.formUnion(itemIDs)
        } else {
            selectedItemIDs.subtract(itemIDs)
        }
        updateCategoryState(category)
        rebuildVisibleRows()
        selectionChanged()
    }

    private func setCategory(_ categoryID: String, expanded: Bool) {
        if expanded {
            expandedCategoryIDs.insert(categoryID)
        } else {
            expandedCategoryIDs.remove(categoryID)
        }
        rebuildVisibleRows()
        invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
    }

    private func setItem(_ item: StorageCleanupItem, selected: Bool) {
        if selected {
            selectedItemIDs.insert(item.id)
        } else {
            selectedItemIDs.remove(item.id)
        }
        if let category = currentSnapshot?.categories.first(where: { $0.id == item.categoryID }) {
            updateCategoryState(category)
        }
        selectionChanged()
    }

    private func rebuildVisibleRows() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for category in currentSnapshot?.categories ?? [] {
            guard let categoryRow = categoryRows[category.id] else { continue }
            categoryRow.setExpanded(expandedCategoryIDs.contains(category.id))
            updateCategoryState(category)
            rowsStack.addArrangedSubview(categoryRow)
            categoryRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            guard expandedCategoryIDs.contains(category.id) else { continue }
            for item in category.items {
                let itemRow = StorageCleanupItemRowView(
                    item: item,
                    selected: selectedItemIDs.contains(item.id)
                )
                itemRow.onSelectionChanged = { [weak self] selected in
                    self?.setItem(item, selected: selected)
                }
                rowsStack.addArrangedSubview(itemRow)
                itemRow.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
    }

    private func updateCategoryState(_ category: StorageCleanupCategory) {
        let selectedCount = category.items.reduce(0) {
            $0 + (selectedItemIDs.contains($1.id) ? 1 : 0)
        }
        let state: NSControl.StateValue
        if selectedCount == 0 {
            state = .off
        } else if selectedCount == category.items.count {
            state = .on
        } else {
            state = .mixed
        }
        categoryRows[category.id]?.setSelectionState(state)
    }

    private func selectionChanged() {
        let items = selectedItems()
        let bytes = items.reduce(0) { $0 + $1.bytes }
        cleanButton.title = bytes > 0 ? "清理所选（\(formatBytes(bytes))）" : "清理所选"
        cleanButton.isEnabled = progress.isHidden && !items.isEmpty
    }

    @objc private func scan() { onScan?() }
    @objc private func clean() { onClean?(selectedItems()) }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
