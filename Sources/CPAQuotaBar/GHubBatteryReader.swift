import Foundation

struct GHubMouseBattery: Sendable {
    let name: String
    let percent: Int
    let isCharging: Bool
}

/// Reads the same localhost WebSocket API used by Logitech G HUB's own UI.
final class GHubBatteryReader: @unchecked Sendable {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: GHubMouseBattery?

        func set(_ value: GHubMouseBattery?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> GHubMouseBattery? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func read(timeout: TimeInterval = 1.5) -> GHubMouseBattery? {
        let result = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        let work = Task { [result] in
            result.set(await readFromGHub())
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            work.cancel()
            return nil
        }
        return result.get()
    }

    private func readFromGHub() async -> GHubMouseBattery? {
        guard let url = URL(string: "ws://127.0.0.1:9010") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url, protocols: ["json"])
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            let devicesPath = "/devices/list"
            let devices = try await request(path: devicesPath, socket: socket)
            guard let payload = devices["payload"] as? [String: Any],
                  let deviceInfos = payload["deviceInfos"] as? [[String: Any]],
                  let mouse = deviceInfos.first(where: Self.isReadableMouse),
                  let id = mouse["id"] as? String else { return nil }

            let name = (mouse["givenName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? mouse["displayName"] as? String
                ?? "罗技鼠标"
            let battery = try await request(path: "/battery/\(id)/state", socket: socket)
            guard let batteryPayload = battery["payload"] as? [String: Any],
                  let percentage = batteryPayload["percentage"] as? NSNumber else { return nil }

            return GHubMouseBattery(
                name: name,
                percent: min(max(percentage.intValue, 0), 100),
                isCharging: batteryPayload["charging"] as? Bool ?? false
            )
        } catch {
            return nil
        }
    }

    private func request(path: String, socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let request: [String: Any] = [
            "msgId": UUID().uuidString.lowercased(),
            "path": path,
            "verb": "GET"
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try await socket.send(.string(text))

        for _ in 0..<8 {
            let message = try await socket.receive()
            let responseData: Data
            switch message {
            case .string(let value):
                responseData = Data(value.utf8)
            case .data(let value):
                responseData = value
            @unknown default:
                continue
            }
            guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  response["path"] as? String == path else { continue }
            return response
        }
        throw CocoaError(.fileReadUnknown)
    }

    private static func isReadableMouse(_ device: [String: Any]) -> Bool {
        guard device["deviceType"] as? String == "MOUSE",
              device["state"] as? String == "ACTIVE" else { return false }
        let capabilities = device["capabilities"] as? [String: Any]
        return capabilities?["hasBatteryStatus"] as? Bool == true
    }
}
