#!/bin/zsh
# 环境光自动亮度:读 MacBook 内置环境光传感器 (CurrentLux) → 映射曲线 → 外接屏亮度。
# 触发:开机/登录 + 每 45 秒。传感器在键盘上方扬声器格栅内,合盖状态下依然工作。
# 当 Super Dashboard (CPAQuotaBar) 正在运行时自动让出控制权,避免双进程争抢 DDC/I2C 总线。
set -u

# Super Dashboard 内置 AutoBrightnessController 已接管环境光采样、锁互斥与暂停策略;双开会争抢 I2C。
if /usr/bin/pgrep -x CPAQuotaBar >/dev/null 2>&1; then
  exit 0
fi

support_dir="$HOME/Library/Application Support/DisplayPanel"
blank_pid_file="$support_dir/blanking.pid"
if [[ -f "$blank_pid_file" ]]; then
  blank_pid="$(<"$blank_pid_file")"
  if [[ "$blank_pid" =~ '^[0-9]+$' ]] && /bin/kill -0 "$blank_pid" 2>/dev/null; then
    exit 0
  fi
fi

# 待恢复熄屏快照存在时不触碰硬件亮度。
if [[ -f "$support_dir/screen-sleep-state.json" || -f "$support_dir/pending-layout.json" ]]; then
  exit 0
fi

# Never query/reconfigure a sleeping display or send DDC during dark wake.
AWAKE_CHECK="${DISPLAY_AWAKE_CHECK:-$HOME/Library/Scripts/display-is-awake}"
[[ -x "$AWAKE_CHECK" ]] && "$AWAKE_CHECK" || exit 0

# ===== 想调就改这里 =====
MIN_PCT=18          # 最暗环境下的外接屏亮度 (%)
MAX_PCT=88          # 最亮环境下的外接屏亮度 (%)
LUX_MAX=800         # 视为"最亮"的环境光 (lux)
GAMMA=1.0           # 曲线指数:>1 偏暗,<1 偏亮
CHANGE_THRESHOLD=6  # 目标变化超过几个百分点才下发(防抖)
# =======================

M1DDC="${M1DDC_BIN:-/opt/homebrew/bin/m1ddc}"
DDC_HELPER="/Applications/Super Dashboard.app/Contents/MacOS/DDCControl"
[[ -x "$DDC_HELPER" ]] || DDC_HELPER="/Applications/显示器控制台.app/Contents/MacOS/DDCControl"
STATE_DIR="$HOME/Library/Application Support/als-auto-brightness"
STATE_FILE="$STATE_DIR/last_target"
PAUSE_FILE="$STATE_DIR/paused_until"
LOG_FILE="$HOME/Library/Logs/als-auto-brightness.log"

[[ -x "$DDC_HELPER" || -x "$M1DDC" ]] || exit 0

/bin/mkdir -p "$STATE_DIR" "$support_dir"

# 手动暂停期内不干预(见 pause-auto-brightness)
if [[ -f "$PAUSE_FILE" ]]; then
  pause_until="$(<"$PAUSE_FILE")"
  [[ "$pause_until" =~ '^[0-9]+$' ]] || pause_until=0
  if (( $(/bin/date +%s) < pause_until )); then
    exit 0
  fi
fi

# 读取环境光传感器
lux="$(ioreg -r -k CurrentLux 2>/dev/null | /usr/bin/sed -n 's/.*"CurrentLux" = \([0-9]*\).*/\1/p' | /usr/bin/head -n 1)"
[[ "$lux" =~ '^[0-9]+$' ]] || exit 0
# Reject invalid/sentinel sensor values before arithmetic or curve mapping.
/usr/bin/awk -v l="$lux" 'BEGIN { exit (l >= 0 && l <= 1000000) ? 0 : 1 }' || exit 0

# lux → 亮度百分比(对数曲线)
target="$(/usr/bin/awk -v l="$lux" -v mn="$MIN_PCT" -v mx="$MAX_PCT" -v lm="$LUX_MAX" -v g="$GAMMA" 'BEGIN {
  if (l < 0) l = 0
  if (l > lm) l = lm
  f = log(1 + l) / log(1 + lm)
  f = f ^ g
  v = mn + (mx - mn) * f
  if (v < mn) v = mn
  if (v > mx) v = mx
  printf "%d", v + 0.5
}')"

# 防抖:与上次下发的目标差异太小就不动
last_target=""
[[ -f "$STATE_FILE" ]] && last_target="$(<"$STATE_FILE")"
if [[ "$last_target" =~ '^[0-9]+$' ]]; then
  delta=$(( target - last_target ))
  (( delta < 0 )) && delta=$(( -delta ))
  if (( delta < CHANGE_THRESHOLD )); then
    exit 0
  fi
fi

updated=0
if [[ -x "$DDC_HELPER" ]]; then
  "$AWAKE_CHECK" || exit 0
  if /usr/bin/python3 -c '
import fcntl, json, os, subprocess, sys
lock_path, helper, val = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
res = subprocess.run([helper, "set", "0x10", val], capture_output=True, text=True, timeout=4)
if res.returncode != 0:
    sys.exit(1)
data = json.loads(res.stdout or "{}")
sys.exit(0 if data.get("ok") and data.get("verified") else 1)
' "$support_dir/screen-sleep.lock" "$DDC_HELPER" "$target" >/dev/null 2>&1; then
    updated=1
  fi
elif [[ -x "$M1DDC" ]]; then
  display_ids="$(
    "$M1DDC" display list 2>/dev/null \
      | /usr/bin/perl -ne 'if(/^\[(\d+)\]\s+(.+?)\s+\([^)]+\)\s*$/){ next if $2 eq "(null)" || $2 =~ /Virtual|RustDesk|Ferry/i; print "$1\n"; }'
  )"
  if [[ -n "$display_ids" ]]; then
    while IFS= read -r display_id; do
      [[ -z "$display_id" ]] && continue
      "$AWAKE_CHECK" || exit 0
      if "$M1DDC" display "$display_id" set luminance "$target" >/dev/null 2>&1; then
        updated=1
      fi
    done <<< "$display_ids"
  fi
fi

if (( updated == 1 )); then
  /bin/echo "$target" > "$STATE_FILE"
  /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') lux=$lux -> ${target}%" >> "$LOG_FILE"
fi
