#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="${RUNNER_TEMP:-/private/tmp}/QuickRecorder-cloud-build"
mkdir -p "$work" dist
xcodebuild -version | tee dist/xcode-version.txt
xcodebuild -project QuickRecorder.xcodeproj -scheme QuickRecorder -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee dist/build.log
app="$work/DerivedData/Build/Products/Release/QuickRecorder Hardened.app"
test -d "$app"
codesign --force --deep --sign - --timestamp=none \
  --entitlements QuickRecorder/QuickRecorder.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tee dist/signature.txt
lipo -archs "$app/Contents/MacOS/QuickRecorder Hardened" | tee dist/architectures.txt
test "$(cat dist/architectures.txt)" = arm64
ditto -c -k --sequesterRsrc --keepParent "$app" dist/QuickRecorder-Hardened-1.6.11-arm64.zip
git archive --format=zip --output=dist/QuickRecorder-Hardened-1.6.11-source.zip HEAD
cp LICENSE dist/LICENSE.txt
shasum -a 256 dist/QuickRecorder-Hardened-1.6.11-*.zip > dist/SHA256SUMS.txt
