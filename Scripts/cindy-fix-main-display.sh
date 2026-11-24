#!/bin/zsh
# Apply the last user-selected layout; the helper guards sleeping displays,
# serializes transactions, verifies state and restores the panel if unplugged.
set -u
manager='/Applications/Super Dashboard.app/Contents/MacOS/DisplayManager'
[[ -x "$manager" ]] || manager='/Applications/显示器控制台.app/Contents/MacOS/DisplayManager'
[[ -x "$manager" ]] || exit 0
"$manager" reconcile "$@" >> "$HOME/Library/Logs/cindy-fix-main-display.log" 2>&1
