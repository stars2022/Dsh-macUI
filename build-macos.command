#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
XCODE_PATH="/Applications/Xcode-beta.app/Contents/Developer"
if [[ ! -d "$XCODE_PATH" ]]; then
  XCODE_PATH="/Applications/Xcode.app/Contents/Developer"
fi

DEVELOPER_DIR="$XCODE_PATH" xcodebuild \
  -project "$ROOT_DIR/deepseek-harness-macos.xcodeproj" \
  -scheme deepseek-harness-macos \
  -configuration Release \
  -derivedDataPath "$ROOT_DIR/.build/macos-derived" \
  CONFIGURATION_BUILD_DIR="$ROOT_DIR/build" \
  CODE_SIGNING_ALLOWED=NO \
  build

xattr -cr "$ROOT_DIR/build/DeepSeek Harness.app"
codesign --force --deep --sign - "$ROOT_DIR/build/DeepSeek Harness.app"
codesign --verify --deep --strict "$ROOT_DIR/build/DeepSeek Harness.app"
open "$ROOT_DIR/build/DeepSeek Harness.app"
