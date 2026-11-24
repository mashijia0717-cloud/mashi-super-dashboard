import ctypes
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import uuid

backup = pathlib.Path(sys.argv[1]).resolve()
receipt = json.loads((backup / "installation-receipt.json").read_text())
dashboard = pathlib.Path("/Applications/Super Dashboard.app")
console = pathlib.Path("/Applications/显示器控制台.app")
scripts = pathlib.Path.home() / "Library/Scripts"

def manifest(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(directory.rglob("*")) if path.is_file()}

current_receipt = json.loads((backup.parent / "验证记录/installed-audit.json").read_text())
assert manifest(dashboard) == current_receipt["dashboardFileHashes"], "Dashboard changed since installation; review before rollback"
assert manifest(console) == current_receipt["consoleFileHashes"], "Display console changed since installation; review before rollback"
assert manifest(backup / dashboard.name)
for application in [backup / dashboard.name, backup / console.name]:
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)], check=True)
if "--apply" not in sys.argv:
    print("Rollback files verified. Add --apply to restore application/helper files; user preferences, live recovery state, login items and power policies are retained. The old application will remain stopped.")
    sys.exit(0)

library = ctypes.CDLL("/usr/lib/libproc.dylib")
for name, expected in [("CPAQuotaBar", dashboard / "Contents/MacOS/CPAQuotaBar"), ("ScreenBlank", dashboard / "Contents/MacOS/ScreenBlank"), ("ScreenBlank", console / "Contents/MacOS/ScreenBlank")]:
    result = subprocess.run(["/usr/bin/pgrep", "-x", name], capture_output=True, text=True)
    for value in result.stdout.split():
        pid = int(value)
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) > 0 and os.fsdecode(buffer.value) == str(expected):
            os.kill(pid, signal.SIGKILL)

def replace_file(source, target):
    temporary = target.with_name("." + target.name + "." + uuid.uuid4().hex)
    shutil.copy2(source, temporary)
    os.replace(temporary, target)

staged = pathlib.Path("/Applications/.Super-Dashboard-rollback-" + uuid.uuid4().hex + ".app")
subprocess.run(["/usr/bin/ditto", str(backup / dashboard.name), str(staged)], check=True)
assert manifest(staged) == manifest(backup / dashboard.name)
os.rename(dashboard, backup / ("回退时保留的3.0.1-" + uuid.uuid4().hex + ".app"))
os.rename(staged, dashboard)
for name in receipt["independentConsoleChangedFiles"]:
    original = backup / console.name / name
    if original.exists():
        replace_file(original, console / name)
    elif (console / name).exists():
        (console / name).unlink()
for name in ["builtin_brightness", "builtin_brightness.c"]:
    replace_file(backup / "Scripts" / name, scripts / name)
for application in [dashboard, console]:
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)], check=True)
print("Restored Super Dashboard 3.0.0 and the original display helpers. The old known display safety defects are restored too. No display commands were issued; the dashboard remains stopped.")
