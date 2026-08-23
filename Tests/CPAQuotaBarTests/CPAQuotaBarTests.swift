import Foundation
import CoreGraphics
import Testing
@testable import CPAQuotaBar

@Test func powerScaleExpandsAndClampsValues() {
    var scale = PowerScale()
    #expect(scale.normalized(25) == 0.5)
    let expanded = scale.normalized(100)
    #expect(expanded == 0.8)
    #expect(scale.maximumWatts == 125)
}

@Test func menuBarNumberSelectionPersistsMultipleMetrics() {
    let suiteName = "CPAQuotaBar-MenuBarNumbers-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    MenuBarNumberOption.saveSelection([.battery, .power], to: defaults)
    #expect(MenuBarNumberOption.savedSelection(from: defaults) == [.battery, .power])
}

@Test func menuBarNumberSelectionMigratesLegacyCodexMode() {
    let suiteName = "CPAQuotaBar-MenuBarMigration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("currentCodex", forKey: "menuBarDisplayMode")
    #expect(MenuBarNumberOption.savedSelection(from: defaults).isEmpty)
}

@Test func systemMetricClampsProgress() {
    let high = SystemMetric(kind: .cpu, title: "CPU", detail: "120%", value: 1.2, accessibilityHelp: "")
    let unavailable = SystemMetric(kind: .power, title: "功率", detail: "不可用", value: nil, accessibilityHelp: "")
    #expect(high.clampedValue == 1)
    #expect(unavailable.clampedValue == nil)
}

@Test func mobileDeviceOutputParserKeepsValuesContainingColons() {
    let values = AppleDeviceBatteryReader.keyValues(
        """
        DeviceName: 测试 iPhone
        BatteryCurrentCapacity: 76
        Note: value:with:colons
        """
    )
    #expect(values["DeviceName"] == "测试 iPhone")
    #expect(values["BatteryCurrentCapacity"] == "76")
    #expect(values["Note"] == "value:with:colons")
}

@Test func nearbyAppleDevicesRefreshEveryFiveMinutes() {
    #expect(AppleDeviceBatteryReader.scanInterval == 300)
}

@Test func displaySceneMenuTitleIncludesIndexAndOffState() {
    #expect(DisplaySceneFormatting.menuTitle(index: 1, name: "内建视网膜显示器", isOff: false) == "关闭显示器 1（内建视网膜显示器）")
    #expect(DisplaySceneFormatting.menuTitle(index: 2, name: "", isOff: false) == "关闭显示器 2")
    #expect(DisplaySceneFormatting.menuTitle(index: 1, name: "Studio Display", isOff: true) == "关闭显示器 1（Studio Display） · 已关闭")
}

@Test func displaySceneShortNameTruncatesLongDisplayNames() {
    #expect(DisplaySceneFormatting.shortName("LG") == "LG")
    #expect(DisplaySceneFormatting.shortName("  DELL U2720Q  ") == "DELL U2720Q")
    let long = DisplaySceneFormatting.shortName("Very Long Cinema Display Name")
    #expect(long.hasSuffix("…"))
    #expect(long.count <= 17)
}

@Test func keepAwakePreferencePersistsEnabledState() {
    let suiteName = "CPAQuotaBar-KeepAwake-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(KeepAwakePreference.load(from: defaults) == false)
    KeepAwakePreference.save(true, to: defaults)
    #expect(KeepAwakePreference.load(from: defaults) == true)
    KeepAwakePreference.save(false, to: defaults)
    #expect(KeepAwakePreference.load(from: defaults) == false)
}

@Test func powerFlowParticlesStayWithinUnitIntervalAndFadeAtEnds() {
    let first = PowerFlowGeometry.particleOffset(phase: 0.1, index: 0, count: 3)
    let second = PowerFlowGeometry.particleOffset(phase: 0.1, index: 1, count: 3)
    let wrapped = PowerFlowGeometry.particleOffset(phase: 0.9, index: 2, count: 3)
    #expect(first >= 0 && first < 1)
    #expect(second >= 0 && second < 1)
    #expect(abs(second - first - (1.0 / 3.0)) < 0.0001)
    #expect(wrapped >= 0 && wrapped < 1)
    #expect(PowerFlowGeometry.particleOpacity(progress: 0) < 0.0001)
    #expect(PowerFlowGeometry.particleOpacity(progress: 1) < 0.0001)
    #expect(PowerFlowGeometry.particleOpacity(progress: 0.5) > 0.99)
}

@Test func powerFlowCubicPointHitsEndpoints() {
    let start = CGPoint(x: 0, y: 0)
    let end = CGPoint(x: 10, y: 10)
    let control1 = CGPoint(x: 0, y: 10)
    let control2 = CGPoint(x: 10, y: 0)
    let atStart = PowerFlowGeometry.cubicPoint(
        t: 0,
        start: start,
        control1: control1,
        control2: control2,
        end: end
    )
    let atEnd = PowerFlowGeometry.cubicPoint(
        t: 1,
        start: start,
        control1: control1,
        control2: control2,
        end: end
    )
    #expect(abs(atStart.x - start.x) < 0.0001)
    #expect(abs(atStart.y - start.y) < 0.0001)
    #expect(abs(atEnd.x - end.x) < 0.0001)
    #expect(abs(atEnd.y - end.y) < 0.0001)
}

@Test func powerFlowRoutingCoversEverySupplyScene() {
    let batteryOnly = PowerFlowRouting(snapshot: powerSnapshot(
        charging: false,
        external: false,
        systemWatts: 18,
        batteryWatts: -18
    ))
    #expect(batteryOnly.mode == .batteryOnly)
    #expect(batteryOnly.batteryToLoadsWatts == 18)
    #expect(batteryOnly.batteryToSystemWatts == 0)

    let direct = PowerFlowRouting(snapshot: powerSnapshot(
        charging: false,
        external: true,
        systemWatts: 18,
        batteryWatts: 0
    ))
    #expect(direct.mode == .adapterDirect)
    #expect(direct.adapterToSystemWatts == 18)
    #expect(direct.adapterToBatteryWatts == 0)

    let charging = PowerFlowRouting(snapshot: powerSnapshot(
        charging: true,
        external: true,
        systemWatts: 18,
        batteryWatts: 12
    ))
    #expect(charging.mode == .adapterCharging)
    #expect(charging.adapterToSystemWatts == 18)
    #expect(charging.adapterToBatteryWatts == 12)

    let assisted = PowerFlowRouting(snapshot: powerSnapshot(
        charging: false,
        external: true,
        systemWatts: 30,
        batteryWatts: -8
    ))
    #expect(assisted.mode == .adapterWithBatteryAssist)
    #expect(assisted.adapterToSystemWatts == 22)
    #expect(assisted.batteryToSystemWatts == 8)
}

private func powerSnapshot(
    charging: Bool,
    external: Bool,
    systemWatts: Double?,
    batteryWatts: Double?
) -> PowerFlowSnapshot {
    PowerFlowSnapshot(
        batteryLevel: 0.8,
        isCharging: charging,
        externalConnected: external,
        chargeLimitPercent: nil,
        adapterWatts: 65,
        inputWatts: systemWatts,
        systemWatts: systemWatts,
        batteryWatts: batteryWatts,
        cpuWatts: systemWatts.map { $0 * 0.4 },
        gpuWatts: systemWatts.map { $0 * 0.2 },
        otherWatts: systemWatts.map { $0 * 0.4 },
        temperatureCelsius: 30,
        timeToFullMinutes: nil,
        lowPowerMode: false,
        nearbyDevices: [],
        sampledAt: Date()
    )
}
