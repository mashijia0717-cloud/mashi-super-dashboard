# Display-Disconnect & Hotplug Safety Architecture (v3.0.6)

## Root Causes Addressed

1. **Virtual Display Misclassification**: Remote desktop virtual displays (such as RustDesk, UU Remote, and other virtual/dummy screens) are strictly excluded from physical external usability checks so unplugging a physical cable never leaves the builtin display dark.
2. **EDID Vendor Calibration**: Calibrated AOC monitor matching across `DDCControl`, `DisplayManager`, and topology predicates to recognize EDID vendor ID `0x05E3` (`1507`) alongside model (`AG275UXM`) and serial (`1010101`) matching.
3. **`ScreenBlank` Asynchronous & Exit Races**: Cancelled stale asynchronous blanking blocks on wake/restore, removed unsafe `atexit` hardware callbacks, required a verified physical external display before dimming the builtin panel, and preserved saved brightness snapshots until restoration succeeds.
4. **`DisplayManager` Transaction & Lid/Sleep Guards**: Rechecked physical external display usability before and after SkyLight/CoreGraphics layout transactions, tracked builtin-disable ownership (`ownedBuiltinRecord`), guarded closed-lid and dark-wake states, and enforced a 15-second confirmation window with automatic native rollback.
5. **Hot-Corner Hardening & Zero Idle Polling**: Enforced a `2×2 px` top-left corner target with `0.9s` dwell time and mouse-drag suppression, immediate keyboard/mouse wake restoration, and event-driven wake listeners with zero idle CPU polling.

## Key Components

- `Helpers/RDDisplayTopology.h`: Shared physical-vs-virtual display filtering, AOC `0x05E3` vendor matching, and usability predicates.
- `Helpers/ScreenBlank.m` & `Helpers/ScreenBlankRegression.inc`: Hardware screen-off state machine, brightness snapshot/restore, file-lock serialization, and 22 isolated safety regression scenarios.
- `Helpers/DisplayManager.swift`: Layout presets (`external-only`, `dual`, `mirror`), 15-second rollback transactions, builtin recovery ownership tracking, and `--check-recovery` / `--safety-regression` entry points.
- `Helpers/DDCControl.m`: Checked DDC/CI VCP read/write transport over Apple Silicon I2C (`m1ddc` discovery) with sleep and lock guards.
- `Sources/CPAQuotaBar/DisplaySafetyRecovery.swift` & `DisplayConsoleService.swift`: Non-blocking recovery checks on app launch, wake, and display parameter notifications.

## Isolated Verification

All automated safety checks run with injected fake topologies and mock brightness callbacks—never mutating live display layouts or hardware brightness:

```bash
./Scripts/test-appkit.sh
'dist/Super Dashboard.app/Contents/MacOS/DisplayManager' --safety-regression
'dist/Super Dashboard.app/Contents/MacOS/ScreenBlank' --safety-regression
```
