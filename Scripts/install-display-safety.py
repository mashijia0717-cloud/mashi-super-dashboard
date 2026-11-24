import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid

release = pathlib.Path(sys.argv[1]).resolve()
project = pathlib.Path(__file__).resolve().parent.parent
dashboard = pathlib.Path("/Applications/Super Dashboard.app")
console = pathlib.Path("/Applications/显示器控制台.app")
scripts = pathlib.Path.home() / "Library/Scripts"
support = pathlib.Path.home() / "Library/Application Support/DisplayPanel"
records = release / "验证记录"
backup = release / ("回退备份-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
process_library = ctypes.CDLL("/usr/lib/libproc.dylib")

def run(arguments, **options):
    return subprocess.run([str(item) for item in arguments], check=True, capture_output=True, text=True, timeout=45, **options).stdout

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest(directory):
    return {str(path.relative_to(directory)): digest(path) for path in sorted(directory.rglob("*")) if path.is_file()}

def executable(pid):
    buffer = ctypes.create_string_buffer(4096)
    return os.fsdecode(buffer.value) if process_library.proc_pidpath(pid, buffer, len(buffer)) > 0 else ""

def processes(name):
    result = subprocess.run(["/usr/bin/pgrep", "-x", name], capture_output=True, text=True)
    return [int(value) for value in result.stdout.split()]

def stop_exact(name, path):
    stopped = []
    for pid in processes(name):
        if executable(pid) == str(path):
            assert executable(pid) == str(path)
            os.kill(pid, signal.SIGKILL)
            stopped.append(pid)
    return stopped

def replace_file(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name("." + destination.name + "." + uuid.uuid4().hex)
    shutil.copy2(source, temporary)
    os.replace(temporary, destination)

def preferences():
    return plistlib.loads(run(["/usr/bin/defaults", "export", "com.local.CPAQuotaBar", "-"]).encode())

def brightness():
    return float(run([scripts / "builtin_brightness", "get"]).strip())

assert release.name == "Super Dashboard-3.0.1"
original_version = plistlib.loads((dashboard / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"]
previous_receipt = None
if original_version == "3.0.0":
    assert manifest(dashboard) == manifest(release.parent / "Super Dashboard-3.0.0/Super Dashboard.app")
else:
    assert original_version == "3.0.1" and "--refresh" in sys.argv
    previous_receipt = json.loads((records / "installed-audit.json").read_text())
    assert manifest(dashboard) == previous_receipt["dashboardFileHashes"]
    assert manifest(console) == previous_receipt["consoleFileHashes"]
retired_dashboard = backup / ("安装时移出的原" + original_version + ".app")
assert "\"AppleClamshellState\" = No" in run(["/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4"])
topology = json.loads(run([dashboard / "Contents/MacOS/DisplayManager", "status"]))
assert any(screen["builtin"] and screen["active"] and screen["main"] for screen in topology["screens"])
assert not any(not screen["builtin"] and screen["active"] for screen in topology["screens"])
before_brightness = brightness()
assert before_brightness > 0.01
assert not (support / "disabled-builtin.json").exists()
new_dashboard = release / "Super Dashboard.app"
run(["/usr/bin/codesign", "--verify", "--deep", "--strict", new_dashboard])
assert plistlib.loads((new_dashboard / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] == "3.0.1"
for helper in ["DisplayManager", "ScreenBlank"]:
    run([new_dashboard / "Contents/MacOS" / helper, "--safety-regression"])

backup.mkdir(mode=0o700)
for application in [dashboard, console]:
    run(["/usr/bin/ditto", application, backup / application.name])
    assert manifest(application) == manifest(backup / application.name)
saved_preferences = preferences()
(backup / "dashboard-preferences.plist").write_bytes(plistlib.dumps(saved_preferences))
before_power = run(["/usr/bin/pmset", "-g", "custom"])
(backup / "power-settings.txt").write_text(before_power)
run(["/usr/bin/ditto", support, backup / "DisplayPanel-state"])
for name in ["builtin_brightness", "builtin_brightness.c", "cindy-fix-main-display.sh", "dim-builtin-display.zsh", "display-wake-listener", "display-wake-listener.m"]:
    target = backup / "Scripts" / name
    target.parent.mkdir(exist_ok=True)
    shutil.copy2(scripts / name, target)
agents = pathlib.Path.home() / "Library/LaunchAgents"
agent_names = ["com.local.CPAQuotaBar.plist", "com.cindy.display-panel.plist", "com.cindy.fix-main-display.plist", "com.cindy.display-wake-listener.plist", "com.mashijia.dim-builtin-display.plist"]
agent_hashes = {name: digest(agents / name) for name in agent_names}
(backup / "LaunchAgents").mkdir()
for name in agent_names:
    shutil.copy2(agents / name, backup / "LaunchAgents" / name)
layout_hash = digest(support / "layout.json")
console_pids = processes("DisplayPanel")

staging = release / ("安装暂存-" + uuid.uuid4().hex)
staging.mkdir()
staged_console = staging / console.name
run(["/usr/bin/ditto", console, staged_console])
for helper in ["DisplayManager", "ScreenBlank", "builtin_brightness"]:
    shutil.copy2(new_dashboard / "Contents/MacOS" / helper, staged_console / "Contents/MacOS" / helper)
info_path = staged_console / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["DisplaySafetyPatchVersion"] = "2026.11.21.1"
info_path.write_bytes(plistlib.dumps(info))
run(["/usr/bin/codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--timestamp=none", staged_console])
run(["/usr/bin/codesign", "--verify", "--deep", "--strict", staged_console])
old_console_manifest = manifest(console)
new_console_manifest = manifest(staged_console)
console_changes = [name for name, value in new_console_manifest.items() if old_console_manifest.get(name) != value]
allowed_changes = {"Contents/Info.plist", "Contents/MacOS/DisplayPanel", "Contents/_CodeSignature/CodeResources", "Contents/MacOS/DisplayManager", "Contents/MacOS/ScreenBlank", "Contents/MacOS/builtin_brightness"}
assert set(console_changes) <= allowed_changes, console_changes
staged_dashboard = pathlib.Path("/Applications/.Super-Dashboard-3.0.1-" + uuid.uuid4().hex + ".app")
run(["/usr/bin/ditto", new_dashboard, staged_dashboard])
assert manifest(staged_dashboard) == manifest(new_dashboard)
stopped = {}
try:
    stopped["ScreenBlank"] = stop_exact("ScreenBlank", console / "Contents/MacOS/ScreenBlank")
    stopped["CPAQuotaBar"] = stop_exact("CPAQuotaBar", dashboard / "Contents/MacOS/CPAQuotaBar")
    os.rename(dashboard, retired_dashboard)
    os.rename(staged_dashboard, dashboard)
    for name in console_changes:
        replace_file(staged_console / name, console / name)
    replace_file(new_dashboard / "Contents/MacOS/builtin_brightness", scripts / "builtin_brightness")
    replace_file(project / "Helpers/builtin_brightness.c", scripts / "builtin_brightness.c")
    assert manifest(dashboard) == manifest(new_dashboard)
    assert manifest(console) == new_console_manifest
    for application in [dashboard, console]:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", application])
    assert agent_hashes == {name: digest(agents / name) for name in agent_names}
    assert layout_hash == digest(support / "layout.json")
    assert saved_preferences == preferences()
    assert before_power == run(["/usr/bin/pmset", "-g", "custom"])
    assert before_brightness == brightness()
    assert processes("DisplayPanel") == console_pids
    run(["/usr/bin/open", "-g", "-a", dashboard])
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        pids = [pid for pid in processes("CPAQuotaBar") if executable(pid) == str(dashboard / "Contents/MacOS/CPAQuotaBar")]
        if len(pids) == 1:
            break
        time.sleep(0.2)
    assert len(pids) == 1
    assert before_brightness == brightness()
    report = {"passed": True, "version": "3.0.1", "bundlePath": str(dashboard), "pid": pids[0], "backup": str(backup),
              "originalRollbackBackup": previous_receipt.get("originalRollbackBackup",previous_receipt["backup"]) if previous_receipt else str(backup),
              "stoppedExactProcesses": stopped, "independentConsolePIDsPreserved": console_pids, "independentConsoleChangedFiles": console_changes,
              "independentConsoleSafetyPatch": info["DisplaySafetyPatchVersion"], "brightnessBefore": before_brightness, "brightnessAfter": brightness(),
              "loginAgentsUnchanged": True, "powerSettingsUnchanged": True, "preferencesUnchanged": True, "externalLayoutPreferenceUnchanged": True,
              "pendingLegacyStateRetained": (support / "screen-sleep-state.json").exists(), "noHardwareWriteCommandsExecuted": True,
              "dashboardFileHashes": manifest(dashboard), "consoleFileHashes": manifest(console)}
    (records / "installed-audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    (backup / "installation-receipt.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in report.items() if not key.endswith("FileHashes")}, ensure_ascii=False, indent=2))
except BaseException:
    for name in console_changes:
        original = backup / console.name / name
        if original.exists():
            replace_file(original, console / name)
        elif (console / name).exists():
            (console / name).unlink()
    for name in ["builtin_brightness", "builtin_brightness.c"]:
        replace_file(backup / "Scripts" / name, scripts / name)
    if retired_dashboard.exists():
        stop_exact("CPAQuotaBar", dashboard / "Contents/MacOS/CPAQuotaBar")
        if dashboard.exists():
            os.rename(dashboard, staging / "未完成安装的新版.app")
        os.rename(retired_dashboard, dashboard)
    raise
