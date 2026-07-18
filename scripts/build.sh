#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Keep the toolchain selection and all generated output on /Volumes/D.
DEVELOPER_DIR=${DEVELOPER_DIR:-/Volumes/D/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

xcodegen generate
xcodebuild \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgeMac \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgePad \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedDataPad \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project SidecarBridge.xcodeproj \
  -scheme SidecarBridgeMac \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "Mac app: $ROOT/.build/DerivedData/Build/Products/Debug/SidecarBridge.app"
echo "Open SidecarBridge.xcodeproj in Xcode to select your team and install SidecarBridgePad on the iPad."
