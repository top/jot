#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds an ad-hoc-signed universal app and an unnotarized DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="build/release"
APP_PATH="build/DerivedData/Build/Products/Release/Jot.app"

echo "▸ Generating project"
xcodegen generate

echo "▸ Building universal Release app"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild build \
    -project Jot.xcodeproj \
    -scheme Jot \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM= \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO

echo "▸ Ad-hoc signing"
codesign --force --sign - --entitlements App/Jot.entitlements "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "▸ Building DMG"
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR"/Jot-*-UNNOTARIZED.dmg
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
scripts/make-dmg.sh "$APP_PATH" "$BUILD_DIR/Jot-$VERSION-UNNOTARIZED.dmg"
