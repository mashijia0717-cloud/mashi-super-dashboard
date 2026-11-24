import Foundation
import Darwin
import Testing
@testable import CPAQuotaBar

@Test func brightnessYieldsToNativeOwnerAndPendingRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = open(directory.appendingPathComponent("screen-sleep.lock").path, O_CREAT | O_RDWR, 0o600)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(!DisplayConsolePaths.withBrightnessAccess(in: directory) { Issue.record("熄屏持锁时发生了亮度写入"); return true })
    try #require(flock(descriptor, LOCK_UN) == 0)
    let record = directory.appendingPathComponent("screen-sleep-state.json")
    let bytes = Data("partial".utf8)
    try bytes.write(to: record)
    #expect(!DisplayConsolePaths.withBrightnessAccess(in: directory) { Issue.record("待恢复时发生了亮度写入"); return true })
    #expect(try Data(contentsOf: record) == bytes)
    try FileManager.default.removeItem(at: record)
    #expect(DisplayConsolePaths.withBrightnessAccess(in: directory) { flock(descriptor, LOCK_EX | LOCK_NB) != 0 })
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
}

@Test func ambientBrightnessRejectsInvalidSensorsAndClampsTheCurve() {
    #expect(AmbientBrightnessCurve.target(lux: -1) == nil)
    #expect(AmbientBrightnessCurve.target(lux: .nan) == nil)
    #expect(AmbientBrightnessCurve.target(lux: .infinity) == nil)
    #expect(AmbientBrightnessCurve.target(lux: 4_294_967_295) == nil)
    #expect(AmbientBrightnessCurve.target(lux: 0) == 18)
    #expect(AmbientBrightnessCurve.target(lux: 800) == 88)
    #expect(AmbientBrightnessCurve.target(lux: 20_000) == 88)
    #expect(AmbientBrightnessCurve.parseLux(#""CurrentLux" = 125"#) == 125)
    #expect(AmbientBrightnessCurve.parseLux("sensor unavailable") == nil)
}

@Test func hotCornerRequiresDwellAndLeavingBeforeRetrigger() {
    var latch = HotCornerLatch()
    let initialCorner = latch.sample(inside: true, near: true, now: -2)
    #expect(!initialCorner)
    _ = latch.sample(inside: false, near: false, now: -1)
    let samples = [
        latch.sample(inside: true, near: true, now: 0),
        latch.sample(inside: true, near: true, now: 0.59),
        latch.sample(inside: true, near: true, now: 0.61),
        latch.sample(inside: true, near: true, now: 1.5),
        latch.sample(inside: false, near: false, now: 2),
        latch.sample(inside: true, near: true, now: 3),
        latch.sample(inside: true, near: true, now: 3.7)
    ]
    #expect(samples == [false, false, true, false, false, false, true])
}
