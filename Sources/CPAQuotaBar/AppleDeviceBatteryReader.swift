import Darwin
import Foundation

/// 通过 macOS 的 MobileDevice 配对通道读取同一局域网中的 iPhone / iPad，
/// 并通过已配对 iPhone 的 companion 服务读取 Apple Watch。
final class AppleDeviceBatteryReader: @unchecked Sendable {
    static let scanInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var cachedDevices = NearbyAppleDeviceBattery.placeholders
    private var isScanning = false
    private var nextScanDate = Date.distantPast
    // 设备名来自 system_profiler（重量级子进程，还会查询蓝牙模块），
    // 只在有设备缺失需要占位名时才刷新，并单独缓存 1 小时。
    private var cachedNearbyNames: [NearbyAppleDeviceKind: String] = [:]
    private var nearbyNamesSampleDate = Date.distantPast

    func snapshot() -> [NearbyAppleDeviceBattery] {
        lock.lock()
        let shouldScan = !isScanning && Date() >= nextScanDate
        if shouldScan {
            isScanning = true
            nextScanDate = Date().addingTimeInterval(Self.scanInterval)
        }
        let result = cachedDevices
        lock.unlock()

        if shouldScan {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let scanned = self.scanDevices()
                self.lock.lock()
                self.cachedDevices = scanned
                self.isScanning = false
                self.lock.unlock()
            }
        }
        return result
    }

    func reset() {
        lock.lock()
        nextScanDate = .distantPast
        lock.unlock()
    }

    func forceRefresh(completion: (@Sendable ([NearbyAppleDeviceBattery]) -> Void)? = nil) {
        lock.lock()
        guard !isScanning else {
            let current = cachedDevices
            lock.unlock()
            completion?(current)
            return
        }
        isScanning = true
        nextScanDate = Date().addingTimeInterval(Self.scanInterval)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let scanned = self.scanDevices()
            self.lock.lock()
            self.cachedDevices = scanned
            self.isScanning = false
            self.lock.unlock()
            completion?(scanned)
        }
    }

    private func scanDevices() -> [NearbyAppleDeviceBattery] {
        guard let toolsDirectory = Self.toolsDirectory() else {
            return unavailableDevices(nearbyNames: nearbyNamesIfStale())
        }

        let deviceIDTool = toolsDirectory.appendingPathComponent("idevice_id").path
        let deviceInfoTool = toolsDirectory.appendingPathComponent("ideviceinfo").path
        let watchTool = toolsDirectory.appendingPathComponent("comptest").path

        var connections: [String: String] = [:]
        for id in Self.lines(Self.run(deviceIDTool, arguments: ["-n"], timeout: 4)) {
            connections[id] = "-n"
        }
        for id in Self.lines(Self.run(deviceIDTool, arguments: ["-l"], timeout: 4)) {
            connections[id] = ""
        }

        var found: [NearbyAppleDeviceKind: NearbyAppleDeviceBattery] = [:]
        for (id, connectionType) in connections {
            let prefix = connectionType.isEmpty ? [] : [connectionType]
            guard let info = Self.run(
                deviceInfoTool,
                arguments: prefix + ["-u", id],
                timeout: 5
            ) else { continue }

            let values = Self.keyValues(info)
            guard let kind = Self.kind(deviceClass: values["DeviceClass"]) else { continue }
            let deviceName = values["DeviceName"] ?? kind.displayName

            guard let batteryOutput = Self.run(
                deviceInfoTool,
                arguments: prefix + ["-u", id, "-q", "com.apple.mobile.battery"],
                timeout: 5
            ) else { continue }
            let battery = Self.keyValues(batteryOutput)
            guard let percentText = battery["BatteryCurrentCapacity"],
                  let percent = Double(percentText) else { continue }
            let charging = Self.boolean(battery["BatteryIsCharging"])
            let now = Date()
            found[kind] = NearbyAppleDeviceBattery(
                kind: kind,
                name: deviceName,
                level: min(max(percent / 100, 0), 1),
                isCharging: charging,
                availability: .available,
                lastUpdated: now
            )

            if kind == .iPhone,
               let watchOutput = Self.run(watchTool, arguments: [id], timeout: 6) {
                let watch = Self.keyValues(watchOutput)
                if let percentText = watch["BatteryCurrentCapacity"],
                   let percent = Double(percentText) {
                    found[.appleWatch] = NearbyAppleDeviceBattery(
                        kind: .appleWatch,
                        name: watch["DeviceName"] ?? NearbyAppleDeviceKind.appleWatch.displayName,
                        level: min(max(percent / 100, 0), 1),
                        isCharging: Self.boolean(watch["BatteryIsCharging"]),
                        availability: .available,
                        lastUpdated: now
                    )
                }
            }
        }

        let needsPlaceholderNames = !found.isEmpty
            && NearbyAppleDeviceKind.allCases.contains { found[$0] == nil }
        let nearbyNames = needsPlaceholderNames ? self.nearbyNamesIfStale() : [:]
        return NearbyAppleDeviceKind.allCases.map { kind in
            if let device = found[kind] { return device }
            let name = nearbyNames[kind] ?? kind.displayName
            return NearbyAppleDeviceBattery(
                kind: kind,
                name: name,
                level: nil,
                isCharging: false,
                availability: nearbyNames[kind] == nil ? .notFound : .pairingRequired,
                lastUpdated: nil
            )
        }
    }

    private func unavailableDevices(
        nearbyNames: [NearbyAppleDeviceKind: String]
    ) -> [NearbyAppleDeviceBattery] {
        NearbyAppleDeviceKind.allCases.map { kind in
            NearbyAppleDeviceBattery(
                kind: kind,
                name: nearbyNames[kind] ?? kind.displayName,
                level: nil,
                isCharging: false,
                availability: nearbyNames[kind] == nil ? .notFound : .pairingRequired,
                lastUpdated: nil
            )
        }
    }

    private func nearbyNamesIfStale() -> [NearbyAppleDeviceKind: String] {
        lock.lock()
        if Date().timeIntervalSince(nearbyNamesSampleDate) < 3600 {
            let cached = cachedNearbyNames
            lock.unlock()
            return cached
        }
        lock.unlock()
        let names = nearbyDeviceNames()
        lock.lock()
        cachedNearbyNames = names
        nearbyNamesSampleDate = Date()
        lock.unlock()
        return names
    }

    private func nearbyDeviceNames() -> [NearbyAppleDeviceKind: String] {
        guard let output = Self.run(
            "/usr/sbin/system_profiler",
            arguments: ["SPBluetoothDataType", "-json"],
            timeout: 5
        ),
        let data = output.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }

        var names: [NearbyAppleDeviceKind: String] = [:]
        Self.collectNearbyDeviceNames(object, into: &names)
        return names
    }

    private static func collectNearbyDeviceNames(
        _ object: Any,
        into names: inout [NearbyAppleDeviceKind: String]
    ) {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let lowered = key.lowercased()
                if lowered.contains("iphone") {
                    names[.iPhone] = names[.iPhone] ?? key
                } else if lowered.contains("ipad") {
                    names[.iPad] = names[.iPad] ?? key
                } else if lowered.contains("apple watch") || lowered.contains("apple watch") {
                    names[.appleWatch] = names[.appleWatch] ?? key
                }
                collectNearbyDeviceNames(value, into: &names)
            }
        } else if let array = object as? [Any] {
            array.forEach { collectNearbyDeviceNames($0, into: &names) }
        }
    }

    private static func toolsDirectory() -> URL? {
        let manager = FileManager.default
        let candidates = [
            Bundle.module.resourceURL?
                .appendingPathComponent("libimobiledevice")
                .appendingPathComponent("bin"),
            Bundle.main.resourceURL?
                .appendingPathComponent("libimobiledevice")
                .appendingPathComponent("bin")
        ].compactMap { $0 }
        return candidates.first {
            manager.isExecutableFile(atPath: $0.appendingPathComponent("idevice_id").path)
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        final class DataBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = Data()
            var data: Data {
                get { lock.withLock { storage } }
                set { lock.withLock { storage = newValue } }
            }
        }
        let box = DataBox()
        let readGroup = DispatchGroup()
        let readHandle = output.fileHandleForReading
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = readHandle.readDataToEndOfFile()
            readGroup.leave()
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            return nil
        }
        try? output.fileHandleForWriting.close()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 0.3)
            }
            _ = readGroup.wait(timeout: .now() + 0.5)
            return nil
        }
        _ = readGroup.wait(timeout: .now() + 1.0)
        guard process.terminationStatus == 0 else { return nil }
        return String(data: box.data, encoding: .utf8)
    }

    static func keyValues(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func lines(_ output: String?) -> [String] {
        output?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            ?? []
    }

    private static func kind(deviceClass: String?) -> NearbyAppleDeviceKind? {
        switch deviceClass?.lowercased() {
        case "iphone": .iPhone
        case "ipad": .iPad
        default: nil
        }
    }

    private static func boolean(_ value: String?) -> Bool {
        ["true", "yes", "1"].contains(value?.lowercased() ?? "")
    }
}
