#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-statusbar.sh
work="${RUNNER_TEMP:-/private/tmp}/QuickRecorder-statusbar-ci"
swiftc Tests/StatusBarPointer.swift -o "$work/post-click"
python3 Tests/StatusBarNativeUI.py "$work/statusbar-harness" "$work/post-click" "$work/ui"
cp "$work/ui/ui-results.json" dist/statusbar-native-ui.json
python3 Tests/StatusBarPopupUI.py "$work/statusbar-harness" "$work/post-click" "$work/popup-ui"
cp "$work/popup-ui/popup-ui-results.json" dist/statusbar-popup-ui.json
