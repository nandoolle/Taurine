#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
xcodebuild -project src/Taurine.xcodeproj -scheme Taurine \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
mkdir -p build
/usr/bin/ditto .build/xcode/Build/Products/Release/Taurine.app build/Taurine.app
cp LICENSE build/Taurine.app/Contents/Resources/
/usr/bin/codesign --force --sign - build/Taurine.app
/usr/bin/codesign --verify --strict build/Taurine.app
printf '\nBuilt: %s/build/Taurine.app\n' "$PWD"
