#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="${RUNNER_TEMP:-/private/tmp}/QuickRecorder-native-ci"
mkdir -p "$work" dist
swiftc -swift-version 5 -parse-as-library \
  QuickRecorder/Supports/RecordingReliability.swift Tests/ReliabilitySmoke.swift \
  -o "$work/reliability-tests"
QR_TEST_CYCLES=100 QR_TEST_REPORT="$PWD/dist/reliability-tests.json" "$work/reliability-tests"
