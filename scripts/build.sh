#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Keep the toolchain selection and all generated output on /Volumes/D.
#
# Store builds must use the released Xcode 26.5 toolchain (17F42). Do not
# honor a caller-provided DEVELOPER_DIR here: that made it too easy to
# accidentally archive with Xcode-beta. The store archive workflow is kept in
# /Volumes/D/xcode/ARCHIVE_AND_PUSH.md; it patches a beta host stamp in the
# archive before export when this Mac is running a beta macOS. This debug/test
# script intentionally does not produce a store archive.
DEVELOPER_DIR=/Volumes/D/Xcode.app/Contents/Developer
export DEVELOPER_DIR

if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
  echo "Stable Xcode 26.5 was not found at $DEVELOPER_DIR" >&2
  exit 2
fi

XCODE_VERSION=$(
  "$DEVELOPER_DIR/usr/bin/xcodebuild" -version |
    awk 'NR == 1 { print $2 }'
)
XCODE_BUILD=$(
  "$DEVELOPER_DIR/usr/bin/xcodebuild" -version |
    awk 'NR == 2 { print $3 }'
)
if [ "$XCODE_VERSION" != "26.5" ] || [ "$XCODE_BUILD" != "17F42" ]; then
  echo "Refusing to build: expected Xcode 26.5 (17F42), found Xcode $XCODE_VERSION ($XCODE_BUILD)." >&2
  exit 2
fi

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
