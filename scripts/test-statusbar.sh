#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="${RUNNER_TEMP:-/private/tmp}/QuickRecorder-statusbar-ci"
mkdir -p "$work" dist
python3 scripts/prepare-statusbar-harness.py "$work/StatusBarHarness.swift"
swiftc -swift-version 5 "$work/StatusBarHarness.swift" -o "$work/statusbar-harness"
QR_TEST_UNIT=1 "$work/statusbar-harness" | tee dist/statusbar-routing-tests.txt
