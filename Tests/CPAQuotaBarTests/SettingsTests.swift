import AppKit
import ServiceManagement
import Testing
@testable import CPAQuotaBar

@Suite(.serialized)
@MainActor
struct SettingsTests {
    @Test func serverPagesExpandInsideThePopoverAndLocalPagesRestoreTheirSize() async throws {
        _ = NSApplication.shared
        let controller = QuotaPopoverViewController()
        controller.showMagpiePage(.routing)
        let routingSize = controller.preferredContentSize
        let available = try #require(NSScreen.main).visibleFrame.size
        #expect(routingSize.width > 400)
        #expect(routingSize.width <= available.width - 16)
        #expect(routingSize.height <= available.height - 16)
        controller.showMagpiePage(.usage)
        #expect(controller.preferredContentSize == routingSize)
        controller.showSystemStatusPage()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.preferredContentSize.width == 400)
        #expect(controller.preferredContentSize.height <= 600)
    }

    private func controls(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(controls)
    }

    @Test func menuBarLinesSaveAndRestoreIndependently() throws {
        _ = NSApplication.shared
        let name = "SettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = AppSettingsViewController(defaults: defaults, loginStatus: { .notRegistered }, applyLogin: { _ in })
        controller.prepareForPresentation()
        let titles = ["第一条（上）", "第二条（中）", "第三条（下）"]
        let popups = try titles.map { title in
            try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.\(title)" } as? NSPopUpButton)
        }
        let selected: [MenuBarLineOption] = [.battery, .power, .mouseBattery]
        for (popup, option) in zip(popups, selected) {
            popup.selectItem(at: try #require(MenuBarLineOption.allCases.firstIndex(of: option)))
        }
        #expect(MenuBarLineOption.savedSelection(from: defaults) == [.cpu, .gpu, .memory])
        try controller.commitSettings()
        #expect(MenuBarLineOption.savedSelection(from: defaults) == selected)
        popups[0].selectItem(at: 0)
        controller.prepareForPresentation()
        #expect(popups[0].selectedItem?.representedObject as? String == "battery")
        defaults.set(["invalid", "power"], forKey: MenuBarLineOption.defaultsKey)
        #expect(MenuBarLineOption.savedSelection(from: defaults) == [.cpu, .power, .memory])
    }

    @Test func cancellationAndRefocusingPreserveCorrectState() throws {
        _ = NSApplication.shared
        let name = "SettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        let controller = AppSettingsViewController(defaults: defaults, loginStatus: { .notRegistered }, applyLogin: { _ in calls += 1 })
        let window = SettingsWindowController(contentController: controller)
        window.window?.alphaValue = 0
        window.window?.ignoresMouseEvents = true
        defer { window.close() }
        window.showWindow(nil)
        let toggle = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.开机启动" } as? NSSwitch)
        toggle.performClick(nil)
        #expect(toggle.state == .on)
        #expect(calls == 0)
        window.showWindow(nil)
        #expect(toggle.state == .on)
        window.close()
        window.showWindow(nil)
        #expect(toggle.state == .off)
        #expect(calls == 0)
        #expect(defaults.persistentDomain(forName: name) == nil)
    }

    @Test func invalidPagesDisableSaveAndUnknownOrderResets() throws {
        _ = NSApplication.shared
        let name = "SettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("cleanFirst", forKey: "dashboardPageOrder")
        let controller = AppSettingsViewController(defaults: defaults, loginStatus: { .notRegistered }, applyLogin: { _ in })
        controller.prepareForPresentation()
        let popup = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.页面顺序" } as? NSPopUpButton)
        #expect(popup.selectedItem?.representedObject as? String == "cleanFirst")
        defaults.set("invalid", forKey: "dashboardPageOrder")
        controller.prepareForPresentation()
        #expect(popup.selectedItem?.representedObject as? String == "default")
        for title in ["状态", "运行", "电源", "清理", "屏幕", "工具", "路由", "用量"] {
            let toggle = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.\(title)" } as? NSSwitch)
            #expect(toggle.accessibilityLabel() == title)
            toggle.performClick(nil)
        }
        let save = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.save" } as? NSButton)
        #expect(!save.isEnabled)
    }

    @Test func failedLoginDoesNotPartiallySaveAndSuccessPersists() throws {
        _ = NSApplication.shared
        let name = "SettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var status: SMAppService.Status = .notRegistered
        var shouldFail = true
        var calls = 0
        let controller = AppSettingsViewController(defaults: defaults, loginStatus: { status }, applyLogin: { enabled in
            calls += 1
            if shouldFail { throw CocoaError(.fileWriteNoPermission) }
            status = enabled ? .enabled : .notRegistered
        })
        controller.prepareForPresentation()
        for title in ["开机启动", "屏幕常亮", "左上角熄屏"] {
            let toggle = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.\(title)" } as? NSSwitch)
            toggle.performClick(nil)
        }
        #expect(throws: (any Error).self) { try controller.commitSettings() }
        #expect(defaults.persistentDomain(forName: name) == nil)
        shouldFail = false
        try controller.commitSettings()
        #expect(KeepAwakePreference.load(from: defaults))
        #expect(defaults.bool(forKey: IntegratedHotCornerController.enabledDefaultsKey))
        controller.prepareForPresentation()
        let corner = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.左上角熄屏" } as? NSSwitch)
        #expect(corner.state == .on)
        corner.performClick(nil)
        #expect(status == .enabled)
        try controller.commitSettings()
        #expect(calls == 2)
        #expect(!defaults.bool(forKey: IntegratedHotCornerController.enabledDefaultsKey))
    }

    @Test func layoutsSupportThreeTabsAndDifferentWindowSizes() throws {
        _ = NSApplication.shared
        let name = "SettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = AppSettingsViewController(defaults: defaults, loginStatus: { .notRegistered }, applyLogin: { _ in })
        let host = SettingsWindowController(contentController: controller)
        host.window?.alphaValue = 0
        host.window?.ignoresMouseEvents = true
        host.showWindow(nil)
        defer { host.close() }
        let window = try #require(host.window)
        let tabs = try #require(controls(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(tabs.segmentCount == 3)
        for size in [NSSize(width: 480, height: 460), NSSize(width: 560, height: 620), NSSize(width: 800, height: 800)] {
            window.setContentSize(size)
            for index in 0...2 {
                tabs.selectedSegment = index
                tabs.sendAction(tabs.action, to: tabs.target)
                controller.view.layoutSubtreeIfNeeded()
                let save = try #require(controls(controller.view).first { $0.identifier?.rawValue == "settings.save" })
                #expect(controller.view.bounds.contains(save.convert(save.bounds, to: controller.view)))
                for scroll in controls(controller.view).compactMap({ $0 as? NSScrollView }) where !scroll.isHiddenOrHasHiddenAncestor {
                    let doc = try #require(scroll.documentView)
                    #expect(abs(doc.frame.width - scroll.contentView.bounds.width) < 1)
                }
            }
        }
    }
}
