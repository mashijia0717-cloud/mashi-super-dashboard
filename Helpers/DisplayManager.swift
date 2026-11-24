import AppKit
import CoreGraphics
import Darwin
import IOKit
import RustDeskDisplayTopology

let helperDirectory = (Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])).resolvingSymlinksInPath().deletingLastPathComponent()
let stateURL = URL(fileURLWithPath:NSHomeDirectory()+"/Library/Application Support/DisplayPanel/layout.json")
let ownedBuiltinURL = stateURL.deletingLastPathComponent().appendingPathComponent("disabled-builtin.json")

func lidIsOpen() -> Bool {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return false }
    defer { IOObjectRelease(root) }
    guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
          CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return !(value as! Bool)
}

func acquireLockWithRetry(_ fd: Int32, operation: Int32, timeoutSeconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeoutSeconds))
    while true {
        if flock(fd, operation | LOCK_NB) == 0 { return true }
        if Date() >= deadline { return false }
        usleep(50_000)
    }
}

func externalOnlyTransition(available: () -> Bool, disable: () throws -> Void, recover: () throws -> Void) throws {
    guard available() else { try recover(); throw NSError(domain:"外接屏不可用，取消关闭内屏",code:1) }
    do { try disable() } catch { try recover(); throw error }
    guard available() else { try recover(); throw NSError(domain:"外接屏已断开，已恢复内屏",code:1) }
}

typealias GetList = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
typealias SetEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY)

struct ScreenSpec: Codable, Equatable {
    var id: UInt32? = nil
    var serial: UInt32; var builtin: Bool; var width: Int; var height: Int; var pixelWidth: Int; var hz: Double; var x: Int32; var y: Int32
}
struct Layout: Codable, Equatable { var name: String; var internalOn: Bool; var mirror: Bool; var screens:[ScreenSpec] }
struct DisplayAvailability {
    var builtin:Bool;var online:Bool;var active:Bool;var asleep:Bool
    var rustDeskVirtual:Bool = false
    var virtualDisplay:Bool = false
    var usableMode:Bool = true
}

func usableExternal(in displays:[DisplayAvailability]) -> Bool {
    displays.contains { !$0.builtin && !$0.rustDeskVirtual && !$0.virtualDisplay && $0.online && $0.active && !$0.asleep && $0.usableMode }
}

// Distinguish a powered-down connected external from physical removal.
// Importantly, when our own disabled-builtin record exists, the lid is open,
// the builtin hardware is enumerated as disabled (online == 0), and no physical
// external display remains connected, `online == 0` is NOT normal display sleep:
// it is a headless deadlocked state where the builtin MUST be re-enabled.
func automaticDisplayDecision(
    online: Int,
    allAsleep: Bool,
    connected: Bool,
    usable: Bool,
    owned: Bool,
    removedOwnedExternal: Bool,
    builtinDisabledWhileLidOpen: Bool = false
) -> String {
    if connected && removedOwnedExternal { return "retry-removal" }
    if builtinDisabledWhileLidOpen && owned && !connected && !usable { return "restore-owned" }
    if (online == 0 || allAsleep) && !removedOwnedExternal { return "asleep-or-unknown" }
    if connected && !usable { return "external-not-ready" }
    if !connected { return owned ? "restore-owned" : "no-owned-state" }
    return "apply"
}

func acquireNativeBlankLease(directory: URL, waitSeconds: TimeInterval = 0) throws -> Int32 {
    let descriptor = open(directory.appendingPathComponent("screen-sleep.lock").path,O_CREAT|O_RDWR,0o600)
    guard descriptor >= 0 else { throw layoutError("无法读取原生关屏锁，未更改布局") }
    guard acquireLockWithRetry(descriptor, operation: LOCK_SH, timeoutSeconds: waitSeconds) else {
        close(descriptor)
        throw layoutError("原生关屏会话正在持有显示状态，未更改布局")
    }
    guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("screen-sleep-state.json").path) else {
        flock(descriptor,LOCK_UN); close(descriptor); throw layoutError("原生关屏恢复尚未完成，保留恢复记录")
    }
    return descriptor
}

func fail(_ message:String) -> Never { output(["ok":false,"error":message]); exit(1) }
func output(_ json:[String:Any]) { if let d=try? JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]) { print(String(decoding:d,as:UTF8.self)) } }

func listAll() -> [CGDirectDisplayID] {
    if let h=sky, let sym=dlsym(h,"CGSGetDisplayList") {
        let f=unsafeBitCast(sym,to:GetList.self); var ids=[CGDirectDisplayID](repeating:0,count:32);var n:UInt32=0
        if f(32,&ids,&n) == .success { return Array(ids.prefix(Int(n))).filter { CGDisplayVendorNumber($0) != 0 || CGDisplayIsOnline($0) != 0 } }
    }
    var ids=[CGDirectDisplayID](repeating:0,count:32);var n:UInt32=0
    guard CGGetOnlineDisplayList(32,&ids,&n) == .success else { return [] }; return Array(ids.prefix(Int(n)))
}

func isVirtual(_ id: CGDirectDisplayID) -> Bool {
    RDQuerySystemVirtualDisplay(id)
}

func isAOC(_ id: CGDirectDisplayID) -> Bool {
    guard CGDisplayIsBuiltin(id) == 0, !isVirtual(id) else { return false }
    // AOC PNP vendor ID is 0x05E3 (1507, "AOC") or serial 1010101 across DP/USB-C/HDMI
    return CGDisplaySerialNumber(id) == 1010101 || CGDisplayVendorNumber(id) == 0x05E3
}

func external() -> CGDirectDisplayID? {
    listAll().first { isAOC($0) && CGDisplayIsOnline($0) != 0 }
}

func anyPhysicalExternal() -> CGDirectDisplayID? {
    listAll().first { CGDisplayIsBuiltin($0) == 0 && !isVirtual($0) && CGDisplayIsOnline($0) != 0 }
}

func builtin() -> CGDirectDisplayID? { listAll().first { CGDisplayIsBuiltin($0) != 0 } }

func isBuiltinDisabledWhileLidOpen() -> Bool {
    guard lidIsOpen(), let b = builtin() else { return false }
    return CGDisplayIsOnline(b) == 0
}

func hasUsableExternal() -> Bool {
    usableExternal(in:listAll().map {
        let builtinFlag = CGDisplayIsBuiltin($0) != 0
        return DisplayAvailability(
            builtin: builtinFlag,
            online: CGDisplayIsOnline($0) != 0,
            active: CGDisplayIsActive($0) != 0,
            asleep: CGDisplayIsAsleep($0) != 0,
            rustDeskVirtual: RDIsManagedVirtual(CGDisplayVendorNumber($0), CGDisplayModelNumber($0), builtinFlag),
            virtualDisplay: isVirtual($0),
            usableMode: CGDisplayBounds($0).width > 1 && CGDisplayBounds($0).height > 1 && CGDisplayCopyDisplayMode($0).map { $0.width > 1 && $0.height > 1 } == true
        )
    })
}

func readBuiltinBrightnessValue() -> Double? {
    let task = Process(), pipe = Pipe()
    task.executableURL = helperDirectory.appendingPathComponent("builtin_brightness")
    task.arguments = ["get"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let value = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite, (0...1).contains(value) else { return nil }
    return value
}

func restoreBuiltinIfNeeded(restoreBrightness:Bool=true, ownedBlankRecovery:Bool=false) throws {
    guard lidIsOpen() else { throw NSError(domain:"上盖关闭或状态未知，延后内屏恢复",code:1) }
    let physicalOnline = listAll().filter { CGDisplayIsOnline($0) != 0 && !isVirtual($0) }
    let disabledRecovery = isBuiltinDisabledWhileLidOpen() && FileManager.default.fileExists(atPath: ownedBuiltinURL.path) && anyPhysicalExternal() == nil
    guard ownedBlankRecovery || disabledRecovery || physicalOnline.isEmpty || !physicalOnline.allSatisfy({ CGDisplayIsAsleep($0) != 0 }) else {
        throw NSError(domain:"正常休眠中，延后内屏恢复",code:1)
    }
    guard let id=builtin() else { throw NSError(domain:"内屏暂未枚举，保留恢复状态",code:1) }
    let wasOffline = CGDisplayIsOnline(id) == 0
    if wasOffline { try changeEnabled(id,true) }
    for _ in 0..<15 {
        if CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0 { break }
        usleep(100_000)
    }
    if !restoreBrightness {
        guard CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0 else {throw NSError(domain:"内屏尚不可用",code:1)}
        return
    }
    var currentBrightness: Double? = nil
    for _ in 0..<(wasOffline ? 8 : 3) {
        if let v = readBuiltinBrightnessValue() {
            currentBrightness = v
            break
        }
        usleep(100_000)
    }
    let owned = (try? Data(contentsOf:ownedBuiltinURL)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
    let saved = owned?["brightness"] as? Double
    if let brightness = currentBrightness {
        if brightness <= 0.02 {
            let preferred = (saved != nil && saved!.isFinite && saved! > 0.05) ? min(1, saved!) : 0.5
            guard run(helperDirectory.appendingPathComponent("builtin_brightness").path, ["set", String(preferred)]) else {
                throw NSError(domain:"内屏亮度恢复失败",code:1)
            }
        }
    } else if wasOffline || owned != nil {
        let preferred = (saved != nil && saved!.isFinite && saved! > 0.05) ? min(1, saved!) : 0.5
        if !run(helperDirectory.appendingPathComponent("builtin_brightness").path, ["set", String(preferred)]) {
            throw NSError(domain:"内屏亮度读取及恢复失败，保留恢复状态",code:1)
        }
    } else {
        throw NSError(domain:"内屏亮度读取失败，保留恢复状态",code:1)
    }
    guard CGDisplayIsOnline(id) != 0, CGDisplayIsActive(id) != 0 else { throw NSError(domain:"内屏尚不可用，保留恢复状态",code:1) }
    try? FileManager.default.removeItem(at:ownedBuiltinURL)
}

func changeEnabled(_ id:CGDirectDisplayID,_ enable:Bool) throws {
    if (CGDisplayIsOnline(id) != 0) == enable { return }
    guard let h=sky,let sym=dlsym(h,"CGSConfigureDisplayEnabled") else { throw NSError(domain:"内屏开关接口不可用",code:1) }
    if !enable && listAll().filter({ CGDisplayIsOnline($0) != 0 && !isVirtual($0) }).count < 2 { throw NSError(domain:"不能关闭最后一块物理屏幕",code:1) }
    if !enable && CGDisplayIsBuiltin(id) != 0 && (!hasUsableExternal() || external().map { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 } != true) { throw NSError(domain:"没有可用的外接屏，保留内建显示器",code:1) }
    let f=unsafeBitCast(sym,to:SetEnabled.self); var config:CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success,let c=config else { throw NSError(domain:"无法创建显示配置",code:1) }
    if !enable && CGDisplayIsInMirrorSet(id) != 0 {
        guard CGConfigureDisplayMirrorOfDisplay(c,id,0) == .success else {CGCancelDisplayConfiguration(c);throw NSError(domain:"无法退出镜像",code:1)}
    }
    let rc=f(c,id,enable)
    if rc != .success { CGCancelDisplayConfiguration(c);throw NSError(domain:"屏幕开关失败",code:Int(rc.rawValue)) }
    if !enable && !hasUsableExternal() {CGCancelDisplayConfiguration(c);throw NSError(domain:"提交前外屏已失效",code:1)}
    let done=CGCompleteDisplayConfiguration(c,.forSession)
    for _ in 0..<25 { if (CGDisplayIsOnline(id) != 0)==enable { return }; usleep(100000) }
    throw NSError(domain:"屏幕开关未生效",code:Int(done.rawValue))
}

func allModes(_ id:CGDirectDisplayID) -> [CGDisplayMode] {
    CGDisplayCopyAllDisplayModes(id,[kCGDisplayShowDuplicateLowResolutionModes:true] as CFDictionary) as? [CGDisplayMode] ?? []
}
func spec(_ id:CGDirectDisplayID) -> ScreenSpec? {
    guard let m=CGDisplayCopyDisplayMode(id) else { return nil }; let b=CGDisplayBounds(id)
    return ScreenSpec(serial:CGDisplaySerialNumber(id),builtin:CGDisplayIsBuiltin(id) != 0,width:m.width,height:m.height,pixelWidth:m.pixelWidth,hz:m.refreshRate,x:Int32(b.origin.x),y:Int32(b.origin.y))
}
func resolveMode(_ id:CGDirectDisplayID,_ s:ScreenSpec) -> CGDisplayMode? {
    let matching = allModes(id).filter { $0.width == s.width && $0.height == s.height && $0.pixelWidth == s.pixelWidth }
    return matching.first { abs($0.refreshRate - s.hz) < 0.01 }
        ?? matching.first { abs($0.refreshRate - s.hz) < 0.6 || s.hz == 0 }
        ?? matching.max { $0.refreshRate < $1.refreshRate }
}
func load() -> Layout? { guard let d=try? Data(contentsOf:stateURL) else { return nil }; return try? JSONDecoder().decode(Layout.self,from:d) }
func save(_ layout:Layout) throws { try FileManager.default.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true); try JSONEncoder().encode(layout).write(to:stateURL,options:.atomic) }
func matches(_ l:Layout, allowNegotiatedRefreshRate: Bool = false) -> Bool {
    if let b=builtin(),(CGDisplayIsOnline(b) != 0) != l.internalOn { return false }
    if let e=external(),(CGDisplayIsInMirrorSet(e) != 0) != l.mirror { return false }
    for s in l.screens {
        guard let id=(s.builtin ? builtin() : external()),let current=spec(id) else { return false }
        if current.width != s.width || current.height != s.height || current.pixelWidth != s.pixelWidth { return false }
        if !allowNegotiatedRefreshRate && s.hz > 0 && abs(current.hz - s.hz) > 0.6 { return false }
        if !l.mirror && (current.x != s.x || current.y != s.y) { return false }
    }
    return true
}
@discardableResult func run(_ path:String,_ args:[String]) -> Bool { let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;do {try p.run();p.waitUntilExit();return p.terminationStatus==0} catch {return false} }

func apply(_ layout:Layout, persist:Bool, automaticReconcile:Bool = false) throws {
    guard let e=external(), CGDisplayIsOnline(e) != 0 else {
        if anyPhysicalExternal() == nil && FileManager.default.fileExists(atPath:ownedBuiltinURL.path) { try? restoreBuiltinIfNeeded() }
        throw NSError(domain:"未连接 AG275UXM",code:1)
    }
    guard CGDisplayIsAsleep(e) == 0 else { throw NSError(domain:"屏幕正在休眠，未操作",code:1) }
    if matches(layout, allowNegotiatedRefreshRate: automaticReconcile) { if persist { try save(layout) };return }
    if layout.internalOn {
        guard let b=builtin() else { throw NSError(domain:"未找到内置屏，请打开电脑上盖",code:1) }
        if CGDisplayIsOnline(b) == 0 && !lidIsOpen() { throw layoutError("请先打开上盖") }
        try changeEnabled(b,true)
        if FileManager.default.fileExists(atPath: ownedBuiltinURL.path) { try restoreBuiltinIfNeeded() }
    }
    if layout.mirror, let b=builtin() {
        var mirrorConfig:CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&mirrorConfig) == .success,let c=mirrorConfig else {throw NSError(domain:"无法创建镜像配置",code:1)}
        guard CGConfigureDisplayMirrorOfDisplay(c,b,e) == .success else {CGCancelDisplayConfiguration(c);throw NSError(domain:"无法设置镜像",code:1)}
        guard external()==e,CGDisplayIsBuiltin(e)==0,hasUsableExternal() else {CGCancelDisplayConfiguration(c);throw NSError(domain:"提交镜像前外屏已失效",code:1)}
        let result=CGCompleteDisplayConfiguration(c,.forSession)
        for _ in 0..<20 {
            if CGDisplayMirrorsDisplay(b)==e {
                var actual=layout;actual.screens=[spec(e),spec(b)].compactMap{$0};if persist {try save(actual)};return
            };usleep(100000)
        }
        throw NSError(domain:"镜像配置未生效",code:Int(result.rawValue))
    }
    var resolved:[(CGDirectDisplayID,ScreenSpec,CGDisplayMode)]=[]
    for s in layout.screens {
        guard let id=(s.builtin ? builtin() : external()),let m=resolveMode(id,s) else { throw NSError(domain:"预设模式当前不可用，请重新选择",code:1) }
        resolved.append((id,s,m))
    }
    let priorBuiltinBrightness: Double? = {
        if let existing = (try? Data(contentsOf: ownedBuiltinURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["brightness"] as? Double,
           existing.isFinite, existing > 0.05 {
            return existing
        }
        return readBuiltinBrightnessValue()
    }()
    var config:CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let c=config else { throw NSError(domain:"无法创建显示配置",code:1) }
    do {
        for (id,s,m) in resolved {
            guard CGConfigureDisplayMirrorOfDisplay(c,id,0) == .success,
                  CGConfigureDisplayWithDisplayMode(c,id,m,nil) == .success,
                  CGConfigureDisplayOrigin(c,id,s.x,s.y) == .success else { throw NSError(domain:"显示模式设置失败",code:1) }
        }
        if layout.mirror,let b=builtin() {
            guard CGConfigureDisplayMirrorOfDisplay(c,b,e) == .success else { throw NSError(domain:"镜像设置失败",code:1) }
        }
    } catch { CGCancelDisplayConfiguration(c);throw error }
    guard external()==e,CGDisplayIsBuiltin(e)==0,hasUsableExternal() else {CGCancelDisplayConfiguration(c);throw NSError(domain:"提交布局前外屏已失效",code:1)}
    guard CGCompleteDisplayConfiguration(c,.forSession) == .success else {throw NSError(domain:"显示配置未提交",code:1)}

    // Wait briefly for the external display to remain active/awake after mode change before disabling builtin.
    var disabledBuiltin = false
    if !layout.internalOn, let b=builtin() {
        for _ in 0..<8 {
            if external() == e && hasUsableExternal() && CGDisplayIsActive(e) != 0 && CGDisplayIsAsleep(e) == 0 { break }
            usleep(80_000)
        }
        try externalOnlyTransition(available:{external()==e && hasUsableExternal() && CGDisplayIsActive(e) != 0 && CGDisplayIsAsleep(e)==0},disable:{
            var record: [String: Any] = ["id": b, "external": e, "externalSerial": CGDisplaySerialNumber(e)]
            if let priorBuiltinBrightness, priorBuiltinBrightness > 0.02 { record["brightness"] = priorBuiltinBrightness }
            try JSONSerialization.data(withJSONObject: record).write(to: ownedBuiltinURL, options: .atomic)
            try changeEnabled(b,false)
            disabledBuiltin = true
        },recover:{try restoreBuiltinIfNeeded()})
    }
    for _ in 0..<15 {
        if !hasUsableExternal() {try restoreBuiltinIfNeeded();throw NSError(domain:"验证期间外屏失效，已恢复内屏",code:1)}
        if matches(layout, allowNegotiatedRefreshRate: automaticReconcile) { if persist { try save(layout) };return }
        usleep(100000)
    }
    if layout.mirror,let b=builtin(),CGDisplayIsActive(b) != 0,CGDisplayMirrorsDisplay(b)==e {
        var actual=layout; actual.screens=[spec(e),spec(b)].compactMap{$0}; if persist {try save(actual)};return
    }
    if disabledBuiltin && !hasUsableExternal() {
        try? restoreBuiltinIfNeeded()
    }
    let detail=resolved.map { id,s,m in "target=\(s) actual=\(String(describing:spec(id)))" }.joined(separator:"; ")
    throw NSError(domain:"配置读回与目标不一致："+detail,code:1)
}

func preset(_ name:String) throws -> Layout {
    guard let e=external(),let current=spec(e) else {throw NSError(domain:"请连接并唤醒外接显示器",code:1)}
    let desiredHz = name=="省电办公" ? 60.0 : 165.0
    let wanted=allModes(e).filter{$0.width==1920 && $0.height==1080 && $0.pixelWidth==3840}.min{abs($0.refreshRate-desiredHz)<abs($1.refreshRate-desiredHz)}
    var es=current
    if let m=wanted {es.width=m.width;es.height=m.height;pixelWidthAssign(&es, m.pixelWidth);es.hz=m.refreshRate}
    es.x=0;es.y=0
    let dual=name=="双屏扩展" || name=="双屏镜像"
    var screens=[es]
    if dual {
        guard let b=builtin() else {throw NSError(domain:"内置屏不可用，请打开上盖",code:1)}
        if CGDisplayIsOnline(b) == 0 && !lidIsOpen() { throw layoutError("请先打开上盖") }
        try changeEnabled(b,true)
        if FileManager.default.fileExists(atPath: ownedBuiltinURL.path) { try restoreBuiltinIfNeeded() }
        guard var bs=spec(b) else {throw NSError(domain:"无法读取内置屏模式",code:1)}
        bs.x=Int32(es.width);bs.y=0;screens.append(bs)
    }
    return Layout(name:name,internalOn:dual,mirror:name=="双屏镜像",screens:screens)
}
func pixelWidthAssign(_ s: inout ScreenSpec, _ pw: Int) { s.pixelWidth = pw }
func layoutError(_ message: String) -> NSError { NSError(domain: message, code: 1) }

func visibleNonManagedDisplays() -> [CGDirectDisplayID] {
    listAll().filter { !RDIsManagedVirtual(CGDisplayVendorNumber($0), CGDisplayModelNumber($0), CGDisplayIsBuiltin($0) != 0) }
}

func physicalDisplays() -> [CGDirectDisplayID] {
    listAll().filter { !isVirtual($0) }
}

func activeLayout(_ name: String) throws -> Layout {
    let online = physicalDisplays().filter { CGDisplayIsOnline($0) != 0 }
    let specs = online.compactMap { id -> ScreenSpec? in
        guard CGDisplayIsAsleep(id) == 0, var screen = spec(id) else { return nil }
        screen.id = id
        return screen
    }
    guard !specs.isEmpty, specs.count == online.count else { throw layoutError("活动屏幕尚不可用，未修改布局") }
    return Layout(name: name, internalOn: specs.contains(where: \.builtin), mirror: online.contains { CGDisplayIsInMirrorSet($0) != 0 }, screens: specs)
}

func sameScreen(_ left: ScreenSpec, _ right: ScreenSpec) -> Bool {
    left.builtin == right.builtin && left.serial == right.serial && (left.id == nil || right.id == nil || left.id == right.id)
}

func sameScreens(_ first: Layout, _ second: Layout) -> Bool {
    first.screens.count == second.screens.count && first.screens.allSatisfy { requested in
        second.screens.filter { sameScreen(requested, $0) }.count == 1
    } && second.screens.allSatisfy { actual in first.screens.filter { sameScreen($0, actual) }.count == 1 }
}

func sameMode(_ first: ScreenSpec, _ second: ScreenSpec) -> Bool {
    first.width == second.width && first.height == second.height && first.pixelWidth == second.pixelWidth && abs(first.hz - second.hz) < 0.02
}

func desktopMatches(_ wanted: Layout, _ actual: Layout) -> Bool {
    sameScreens(wanted, actual) && wanted.internalOn == actual.internalOn && wanted.mirror == actual.mirror && wanted.screens.allSatisfy { requested in
        actual.screens.contains { sameScreen(requested, $0) && sameMode(requested, $0) && (wanted.mirror || (requested.x == $0.x && requested.y == $0.y)) }
    }
}

func applyActiveModes(_ layout: Layout) throws {
    let actual = try activeLayout(layout.name)
    guard sameScreens(layout, actual), layout.internalOn == actual.internalOn, layout.mirror == actual.mirror else { throw layoutError("屏幕连接或布局已变化，请刷新后重试") }
    if desktopMatches(layout, actual) { return }
    guard !actual.mirror else { throw layoutError("请先退出镜像，再调整单屏分辨率") }
    var transaction: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&transaction) == .success, let config = transaction else { throw layoutError("无法开始显示配置") }
    do {
        for requested in layout.screens {
            guard let previous = actual.screens.first(where: { sameScreen(requested, $0) }), let id = previous.id else { throw layoutError("目标显示器已断开") }
            if !sameMode(previous, requested) {
                guard let mode = resolveMode(id, requested), CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else { throw layoutError("目标显示器不支持所选模式") }
            }
            if requested.x != previous.x || requested.y != previous.y {
                guard CGConfigureDisplayOrigin(config, id, requested.x, requested.y) == .success else { throw layoutError("无法配置双屏排列") }
            }
        }
        guard desktopMatches(actual, try activeLayout(layout.name)) else { throw layoutError("提交前屏幕已变化") }
    } catch { CGCancelDisplayConfiguration(config); throw error }
    guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw layoutError("显示模式未提交") }
    for _ in 0..<12 {
        if let current = try? activeLayout(layout.name), desktopMatches(layout, current) { return }
        usleep(100_000)
    }
    throw layoutError("读回的显示配置与请求不一致")
}

struct PendingLayout: Codable {
    var token: String
    var layout: Layout
    var modeOnly: Bool? = nil
    var proposed: Layout? = nil
    var expires: TimeInterval? = nil
}
struct LayoutTrials {
    let url: URL
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    func read() throws -> PendingLayout? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingLayout.self, from: Data(contentsOf: url))
    }
    func write(_ trial: PendingLayout) throws { try JSONEncoder().encode(trial).write(to: url, options: .atomic) }
    func start(before: Layout, modeOnly: Bool, arm: (String) throws -> Void, change: () throws -> Layout, restore: (PendingLayout) throws -> Void) throws -> PendingLayout {
        guard try read() == nil else { throw layoutError("上一项配置仍待确认或恢复") }
        var trial = PendingLayout(token: UUID().uuidString, layout: before, modeOnly: modeOnly, expires: now() + 15)
        try write(trial)
        do { try arm(trial.token) } catch { try FileManager.default.removeItem(at: url); throw error }
        do {
            trial.proposed = try change()
            trial.expires = now() + 15
            try write(trial)
            return trial
        } catch {
            try restore(trial)
            try FileManager.default.removeItem(at: url)
            throw error
        }
    }
    func finish(token: String, keep: Bool, automatic: Bool, restore: (PendingLayout) throws -> Void, confirm: (PendingLayout) throws -> Void) throws {
        guard let trial = try read(), trial.token == token else {
            if automatic { return }
            throw layoutError("这次配置已过期或已处理，请刷新")
        }
        if keep {
            guard trial.expires.map({ $0 > now() }) ?? true else { throw layoutError("确认时限已过") }
            try confirm(trial)
        } else {
            do {
                try restore(trial)
            } catch {
                // If automatic deadline rollback failed because external was unplugged and builtin is already online, clear stale trial file.
                if automatic, external() == nil, let b = builtin(), CGDisplayIsOnline(b) != 0 {
                    try? FileManager.default.removeItem(at: url)
                }
                throw error
            }
        }
        try FileManager.default.removeItem(at: url)
    }
}
let trials = LayoutTrials(url: stateURL.deletingLastPathComponent().appendingPathComponent("pending-layout.json"))

func restoreTrial(_ trial: PendingLayout) throws {
    if trial.modeOnly == true { try applyActiveModes(trial.layout) }
    else if let monitor = external() {
        let current = try activeLayout(trial.layout.name)
        let matchingExternal = trial.layout.screens.contains {
            !$0.builtin && ($0.serial == CGDisplaySerialNumber(monitor) || isAOC(monitor))
        }
        guard !current.screens.contains(where: { !$0.builtin && $0.id != monitor }), matchingExternal else {
            throw layoutError("外屏拓扑已更换，取消旧布局回退")
        }
        var sanitized = trial.layout
        for idx in sanitized.screens.indices { sanitized.screens[idx].id = nil }
        try apply(sanitized, persist: trial.expires == nil)
    }
    else if FileManager.default.fileExists(atPath: ownedBuiltinURL.path) || isBuiltinDisabledWhileLidOpen() {
        try restoreBuiltinIfNeeded(ownedBlankRecovery: true)
    }
    else { throw layoutError("原显示器未连接，无法恢复原布局") }
}

let args=CommandLine.arguments
let op=args.count>1 ? args[1] : "status"
if op == "--layout-regression" {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let screen = ScreenSpec(id: 1, serial: 77, builtin: true, width: 1440, height: 900, pixelWidth: 2880, hz: 60, x: 0, y: 0)
        let original = Layout(name: "现场布局", internalOn: true, mirror: false, screens: [screen])
        var desired = original; desired.screens[0].hz = 120
        var current = original
        var saved: Layout?
        var clock: TimeInterval = 1000
        var actions: [String] = []
        var cases: [String] = []
        let store = LayoutTrials(url: folder.appendingPathComponent("trial.json"), now: { clock })
        func restore(_ trial: PendingLayout) { current = trial.layout; actions.append("restore") }
        func start() throws -> PendingLayout {
            try store.start(before: current, modeOnly: true, arm: { _ in actions.append("arm") }, change: { current = desired; actions.append("apply"); return current }, restore: restore)
        }
        func finish(_ trial: PendingLayout, keep: Bool, automatic: Bool = false) throws {
            try store.finish(token: trial.token, keep: keep, automatic: automatic, restore: restore) { saved = $0.proposed }
        }
        let first = try start()
        precondition(actions == ["arm", "apply"] && saved == nil && current == desired && first.expires == 1015)
        cases.append("watchdog-before-first-change-and-live-baseline")
        do { _ = try start(); fail("second trial clobbered first") } catch {}
        var stale = first; stale.token = "stale"
        do { try finish(stale, keep: true); fail("stale token confirmed") } catch {}
        try finish(stale, keep: false, automatic: true)
        let pending = try store.read(); precondition(pending?.token == first.token && current == desired)
        cases.append("overlap-and-stale-token")
        do { try store.finish(token: first.token, keep: true, automatic: false, restore: restore, confirm: { _ in throw layoutError("injected") }); fail("false success") } catch {}
        let stillPending = try store.read(); precondition(stillPending?.token == first.token)
        try finish(first, keep: false); precondition(current == original && saved == nil)
        cases.append("failed-confirm-retry-and-immediate-rollback")
        let second = try start(); clock += 16
        do { try finish(second, keep: true); fail("late confirmation") } catch {}
        try finish(second, keep: false, automatic: true); precondition(current == original && saved == nil)
        cases.append("deadline-rollback-without-writing-preference")
        let third = try start(); try finish(third, keep: true); try finish(third, keep: false, automatic: true)
        precondition(current == desired && saved == desired)
        cases.append("confirmed-trial-survives-stale-watchdog")
        current = original; actions = []
        do {
            _ = try store.start(before: current, modeOnly: true, arm: { _ in throw layoutError("injected") }, change: { actions.append("apply"); return desired }, restore: restore)
            fail("unarmed apply")
        } catch {}
        precondition(actions.isEmpty && current == original)
        cases.append("watchdog-failure-before-mutation")
        do {
            _ = try store.start(before: current, modeOnly: true, arm: { _ in }, change: { current = desired; throw layoutError("injected") }, restore: restore)
            fail("partial failure accepted")
        } catch {}
        let cleared = try store.read(); precondition(current == original && cleared == nil)
        cases.append("partial-apply-restored-from-actual-desktop")
        var replacement = original; replacement.screens[0].id = 99
        precondition(!sameScreens(original, replacement))
        replacement = original; replacement.screens[0].id = nil
        precondition(sameScreens(original, replacement))
        replacement.screens.append(replacement.screens[0]); precondition(!sameScreens(original, replacement))
        cases.append("temporary-identities-legacy-presets-and-topology-loss")
        output(["ok": true, "cases": cases, "realDisplayWrites": 0]); exit(0)
    } catch { fail(error.localizedDescription) }
}
if op == "--lifecycle-regression" {
    let cases: [(String, Int, Bool, Bool, Bool, Bool, Bool, Bool, String)] = [
        ("unowned-internal-only",1,false,false,false,false,false,false,"no-owned-state"),
        ("owned-unplug",1,false,false,false,true,false,false,"restore-owned"),
        ("normal-screen-sleep",1,true,false,false,true,false,false,"asleep-or-unknown"),
        ("empty-enumeration",0,true,false,false,true,false,false,"asleep-or-unknown"),
        ("known-unplug-empty-topology",0,true,false,false,true,true,false,"restore-owned"),
        ("owned-unplug-builtin-disabled-zero-online",0,true,false,false,true,false,true,"restore-owned"),
        ("known-unplug-stale-online",1,false,true,true,true,true,false,"retry-removal"),
        ("connected-but-powered-off",1,true,true,false,true,false,true,"asleep-or-unknown"),
        ("external-starting-up",2,false,true,false,true,false,false,"external-not-ready"),
        ("aoc-online-layout",1,false,true,true,true,false,false,"apply"),
        ("aoc-first-online",2,false,true,true,false,false,false,"apply")
    ]
    for row in cases {
        precondition(automaticDisplayDecision(online:row.1,allAsleep:row.2,connected:row.3,usable:row.4,owned:row.5,removedOwnedExternal:row.6,builtinDisabledWhileLidOpen:row.7) == row.8,row.0)
    }
    precondition(!usableExternal(in:[DisplayAvailability(builtin:false,online:true,active:true,asleep:false,usableMode:false)]))
    precondition(!usableExternal(in:[DisplayAvailability(builtin:false,online:true,active:true,asleep:false,virtualDisplay:true,usableMode:true)]))
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let owner = open(directory.appendingPathComponent("screen-sleep.lock").path,O_CREAT|O_RDWR,0o600)
        precondition(owner >= 0 && flock(owner,LOCK_EX|LOCK_NB) == 0)
        do { let lease = try acquireNativeBlankLease(directory:directory); close(lease); fail("active native owner admitted layout writer") } catch {}
        flock(owner,LOCK_UN); close(owner)
        let record = directory.appendingPathComponent("screen-sleep-state.json")
        let bytes = Data("{invalid-partial-recovery".utf8)
        try bytes.write(to:record)
        do { let lease = try acquireNativeBlankLease(directory:directory); close(lease); fail("unrestored native state admitted layout writer") } catch {}
        let preserved = try Data(contentsOf:record); precondition(preserved == bytes)
        try FileManager.default.removeItem(at:record)
        let lease = try acquireNativeBlankLease(directory:directory)
        let challenger = open(directory.appendingPathComponent("screen-sleep.lock").path,O_RDWR)
        precondition(challenger >= 0 && flock(challenger,LOCK_EX|LOCK_NB) != 0)
        close(challenger); flock(lease,LOCK_UN); close(lease)
    } catch { fail(error.localizedDescription) }
    output(["ok":true,"cases":cases.map { $0.0 } + ["invalid-external-mode-never-disables-builtin","ferry-virtual-never-blocks-builtin-recovery","active-native-lock-exclusion","partial-record-preserved","layout-lease-prevents-blank-start"],"realDisplayWrites":0]);exit(0)
}
if op=="--self-test" || op=="--safety-regression" {
    let internalScreen=DisplayAvailability(builtin:true,online:true,active:true,asleep:false)
    let connected=DisplayAvailability(builtin:false,online:true,active:true,asleep:false)
    let disconnected=DisplayAvailability(builtin:false,online:false,active:true,asleep:false)
    let disabled=DisplayAvailability(builtin:false,online:true,active:false,asleep:false)
    let sleeping=DisplayAvailability(builtin:false,online:true,active:true,asleep:true)
    precondition(!usableExternal(in:[]))
    precondition(!usableExternal(in:[internalScreen]))
    precondition(!usableExternal(in:[internalScreen,disconnected]))
    precondition(!usableExternal(in:[internalScreen,disabled]))
    precondition(!usableExternal(in:[internalScreen,sleeping]))
    precondition(usableExternal(in:[internalScreen,connected]))
    let virtual = DisplayAvailability(builtin:false,online:true,active:true,asleep:false,rustDeskVirtual:true)
    let ferry = DisplayAvailability(builtin:false,online:true,active:true,asleep:false,virtualDisplay:true)
    precondition(!usableExternal(in:[internalScreen,virtual]))
    precondition(!usableExternal(in:[internalScreen,ferry]))
    precondition(usableExternal(in:[internalScreen,virtual,connected]))
    var cases=[String]()
    for scenario in ["lost-before-disable","lost-after-disable","disable-failed","connected"] {
        var available=true,commands=[String]()
        do {
            try externalOnlyTransition(available:{
                if scenario=="lost-before-disable" {return false};return available
            },disable:{
                commands.append("disable")
                if scenario=="lost-after-disable" {available=false}
                if scenario=="disable-failed" {throw NSError(domain:"injected",code:1)}
            },recover:{commands.append("restore")})
            precondition(scenario=="connected")
        } catch {precondition(scenario != "connected")}
        if scenario=="connected" {precondition(commands==["disable"])}
        else if scenario=="lost-before-disable" {precondition(commands==["restore"])}
        else {precondition(commands==["disable","restore"])}
        cases.append(scenario)
    }
    output(["ok":true,"displaySafetyCases":10,"transitionCases":cases,"realDisplayWrites":0,"rustDeskVirtualExcluded":true,"ferryVirtualExcluded":true]);exit(0)
}
if op == "--check-recovery" {
    let online = physicalDisplays().filter { CGDisplayIsOnline($0) != 0 }
    let owned = (try? Data(contentsOf:ownedBuiltinURL)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
    let directory = stateURL.deletingLastPathComponent()
    let lock = open(directory.appendingPathComponent("screen-sleep.lock").path,O_RDONLY)
    let nativeLocked = lock >= 0 && flock(lock,LOCK_SH|LOCK_NB) != 0
    if lock >= 0 { flock(lock,LOCK_UN); close(lock) }
    let nativeRecord = FileManager.default.fileExists(atPath:directory.appendingPathComponent("screen-sleep-state.json").path)
    let decision = automaticDisplayDecision(
        online: online.count,
        allAsleep: !online.isEmpty && online.allSatisfy { CGDisplayIsAsleep($0) != 0 },
        connected: anyPhysicalExternal() != nil,
        usable: hasUsableExternal(),
        owned: owned != nil,
        removedOwnedExternal: false,
        builtinDisabledWhileLidOpen: isBuiltinDisabledWhileLidOpen()
    )
    output(["ok":true,"readOnly":true,"decision":nativeLocked || nativeRecord ? "native-recovery-owner" : decision,"nativeLocked":nativeLocked,"nativeRecord":nativeRecord,"ownedBuiltinRecord":owned != nil,"lidOpen":lidIsOpen(),"physicalOnline":online,"realDisplayWrites":0]);exit(0)
}
if op=="status" {
    let screens:[[String:Any]]=visibleNonManagedDisplays().map { id in
        let m=CGDisplayCopyDisplayMode(id);let b=CGDisplayBounds(id)
        let virtualFlag = isVirtual(id)
        return ["id":id,"serial":CGDisplaySerialNumber(id),"vendor":CGDisplayVendorNumber(id),"builtin":CGDisplayIsBuiltin(id) != 0,"virtual":virtualFlag,"active":CGDisplayIsOnline(id) != 0,"online":CGDisplayIsOnline(id) != 0,"asleep":CGDisplayIsAsleep(id) != 0,"usable":CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsAsleep(id) == 0,"main":CGDisplayIsMain(id) != 0,"mirror":CGDisplayIsInMirrorSet(id) != 0,"width":m?.width ?? 0,"height":m?.height ?? 0,"pixelWidth":m?.pixelWidth ?? 0,"pixelHeight":m?.pixelHeight ?? 0,"hz":m?.refreshRate ?? 0,"x":b.origin.x,"y":b.origin.y]
    }
    var result: [String: Any] = ["ok": true, "screens": screens, "preset": load()?.name ?? "未保存"]
    if let pending = try? trials.read(), let expires = pending.expires {
        result["pendingToken"] = pending.token; result["expires"] = expires
    }
    output(result); exit(0)
}
if op=="modes",args.count==3,let id=UInt32(args[2]),listAll().contains(id) {
    var seen=Set<String>();var rows=[[String:Any]]()
    for m in allModes(id) where m.width>=800 && m.height>=600 {
        let key="\(m.width)-\(m.height)-\(m.pixelWidth)-\(m.refreshRate)"
        if seen.insert(key).inserted {rows.append(["width":m.width,"height":m.height,"pixelWidth":m.pixelWidth,"pixelHeight":m.pixelHeight,"hz":m.refreshRate])}
    }
    output(["ok":true,"modes":rows]);exit(0)
}

try? FileManager.default.createDirectory(at:stateURL.deletingLastPathComponent(),withIntermediateDirectories:true)
let fd=open(stateURL.deletingLastPathComponent().appendingPathComponent("layout.lock").path,O_CREAT|O_RDWR,0o600)
let isBackgroundRecoveryOp = ["reconcile", "safety-recover", "recover-builtin"].contains(op)
let lockAcquired: Bool
if fd < 0 {
    lockAcquired = false
} else if op == "rollback" {
    lockAcquired = flock(fd, LOCK_EX) == 0
} else if isBackgroundRecoveryOp {
    lockAcquired = acquireLockWithRetry(fd, operation: LOCK_EX, timeoutSeconds: 2.5)
} else {
    lockAcquired = flock(fd, LOCK_EX | LOCK_NB) == 0
}
guard lockAcquired else {
    if fd >= 0 { close(fd) }
    fail("另一项显示设置正在应用，请稍后重试")
}
defer {flock(fd,LOCK_UN);close(fd)}

if op == "rollback", args.count == 3 {
    while let trial = try? trials.read(), trial.token == args[2], let expiry = trial.expires {
        let remaining = expiry - Date().timeIntervalSince1970
        if remaining <= 0 { break }
        flock(fd, LOCK_UN)
        Thread.sleep(forTimeInterval: min(1, remaining))
        guard flock(fd, LOCK_EX) == 0 else { fail("无法获取回退锁") }
    }
}
let blankFD: Int32
do {
    blankFD = op == "recover-builtin" ? -1 : try acquireNativeBlankLease(directory:stateURL.deletingLastPathComponent(), waitSeconds: isBackgroundRecoveryOp ? 0.6 : 0)
}
catch { fail(error.localizedDescription) }
defer { if blankFD >= 0 { flock(blankFD,LOCK_UN); close(blankFD) } }

let ownedState = (try? Data(contentsOf:ownedBuiltinURL)).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
let removalID = args.firstIndex(of:"--observed-removal").flatMap { $0+1 < args.count ? UInt32(args[$0+1]) : nil }
let removedOwnedExternal = removalID != nil && (
    (ownedState?["external"] as? NSNumber)?.uint32Value == removalID
    || (ownedState != nil && anyPhysicalExternal() == nil)
)

if op == "reconcile" || op == "safety-recover" {
    let online = physicalDisplays().filter { CGDisplayIsOnline($0) != 0 }
    let connectedExternal = op == "reconcile" ? external() != nil : anyPhysicalExternal() != nil
    let decision = automaticDisplayDecision(
        online: online.count,
        allAsleep: online.isEmpty || online.allSatisfy { CGDisplayIsAsleep($0) != 0 },
        connected: connectedExternal,
        usable: hasUsableExternal(),
        owned: ownedState != nil,
        removedOwnedExternal: removedOwnedExternal,
        builtinDisabledWhileLidOpen: isBuiltinDisabledWhileLidOpen()
    )
    if decision == "retry-removal" { fail("拔屏事件后的拓扑尚未收敛，保留恢复记录") }
    if decision == "external-not-ready" { fail("外接屏刚上线但尚不可用，保留内屏并等待后续事件") }
    if !["apply","restore-owned"].contains(decision) {
        output(["ok":true,"skipped":decision]);exit(0)
    }
}
do {
    if ["confirm", "rollback-now", "rollback"].contains(op), args.count == 3 {
        try trials.finish(token: args[2], keep: op == "confirm", automatic: op == "rollback", restore: restoreTrial) { trial in
            guard let proposed = trial.proposed else { return }
            guard desktopMatches(proposed, try activeLayout(proposed.name)) else { throw layoutError("确认前屏幕配置已变化") }
            if proposed.screens.contains(where: { !$0.builtin && ($0.serial == 1010101 || external() != nil) }) { try save(proposed) }
        }
    } else if op=="safety-recover" {
        guard FileManager.default.fileExists(atPath:ownedBuiltinURL.path) else {output(["ok":true,"skipped":"no-owned-state"]);exit(0)}
        guard !hasUsableExternal() else {output(["ok":true,"skipped":"external-available"]);exit(0)}
        try restoreBuiltinIfNeeded(ownedBlankRecovery: removedOwnedExternal || isBuiltinDisabledWhileLidOpen())
    } else if op=="recover-builtin" {
        try restoreBuiltinIfNeeded(restoreBrightness:!args.contains("--enable-only"),ownedBlankRecovery:args.contains("--owned-blank-recovery") || isBuiltinDisabledWhileLidOpen())
    } else if op=="reconcile" {
        if let trial = try trials.read(), (trial.expires ?? 0) > Date().timeIntervalSince1970, external() != nil { output(["ok":true,"skipped":"layout-trial"]); exit(0) }
        if external()==nil {
            if anyPhysicalExternal() == nil && FileManager.default.fileExists(atPath:ownedBuiltinURL.path) {
                try restoreBuiltinIfNeeded(ownedBlankRecovery: removedOwnedExternal || isBuiltinDisabledWhileLidOpen())
            }
            output(["ok":true,"skipped":"external-disconnected"]);exit(0)
        }
        if let e=external(),CGDisplayIsAsleep(e) != 0 {output(["ok":true,"skipped":"asleep"]);exit(0)}
        if let layout=load() {try apply(layout,persist:false,automaticReconcile:true)}
    } else if op=="preset",args.count==3,["外接专注","双屏扩展","双屏镜像","省电办公"].contains(args[2]) {
        let old=load()
        do {try apply(try preset(args[2]),persist:true)} catch {if let old {try? apply(old,persist:false)};throw error}
    } else if op == "apply", args.count == 3 {
        let layout = try JSONDecoder().decode(Layout.self, from: Data(args[2].utf8))
        let old = load()
        do { try apply(layout, persist: true) } catch { if let old { try? apply(old, persist: false) }; throw error }
    } else if ["guarded-mode", "guarded-preset", "guarded-apply"].contains(op), args.count == 3 {
        let before = try activeLayout(load()?.name ?? "原显示配置")
        let requested = op == "guarded-preset" ? nil : try JSONDecoder().decode(Layout.self, from: Data(args[2].utf8))
        let modeOnly = op == "guarded-mode" || requested.map { sameScreens($0, before) && $0.mirror == before.mirror } == true
        if op == "guarded-preset" && !["外接专注", "双屏扩展", "双屏镜像", "省电办公"].contains(args[2]) { throw layoutError("未知的布局预设") }
        if !modeOnly {
            let known: (ScreenSpec) -> Bool = { $0.builtin || $0.serial == 1010101 || external() != nil }
            guard external() != nil, before.screens.allSatisfy(known), requested?.screens.allSatisfy(known) ?? true else { throw layoutError("所选布局需要原 AOC 显示器") }
        }
        if let prior = try trials.read(), let expires = prior.expires, expires <= Date().timeIntervalSince1970 {
            if sameScreens(prior.layout, before) || (prior.modeOnly != true && external() != nil) || FileManager.default.fileExists(atPath: ownedBuiltinURL.path) {
                try? restoreTrial(prior)
            }
            try FileManager.default.removeItem(at: trials.url)
            throw layoutError("上一项显示配置已到期，请刷新后重试")
        }
        let trial = try trials.start(before: before, modeOnly: modeOnly, arm: { token in
            let process = Process()
            process.executableURL = helperDirectory.appendingPathComponent("DisplayManager")
            process.arguments = ["rollback", token]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        }, change: {
            let layout = try requested ?? preset(args[2])
            if modeOnly { try applyActiveModes(layout) } else { try apply(layout, persist: false) }
            return try activeLayout(layout.name)
        }, restore: restoreTrial)
        output(["ok": true, "token": trial.token, "expires": trial.expires ?? 0]); exit(0)
    } else { fail("无效显示设置参数") }
    output(["ok":true,"preset":load()?.name ?? "未保存"])
} catch {fail((error as NSError).domain)}
