#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
# SMAppService recusa assinatura ad-hoc no register(): Developer ID obrigatório.
identity="${TAURINE_SIGN_IDENTITY-}"
if [ -z "$identity" ]; then
    printf 'error: defina TAURINE_SIGN_IDENTITY com sua Developer ID Application.\n' >&2
    /usr/bin/security find-identity -v -p codesigning >&2 || true
    exit 1
fi
xcodebuild -project src/Taurine.xcodeproj -scheme Taurine \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
mkdir -p build
/usr/bin/ditto .build/xcode/Build/Products/Release/Taurine.app build/Taurine.app
cp LICENSE build/Taurine.app/Contents/Resources/
sign_flags=(--force --options runtime --sign "$identity")
/usr/bin/codesign "${sign_flags[@]}" --identifier dev.taurine.helper build/Taurine.app/Contents/Library/LaunchDaemons/dev.taurine.helper
/usr/bin/codesign "${sign_flags[@]}" build/Taurine.app
/usr/bin/codesign --verify --strict build/Taurine.app
printf '\nBuilt: %s/build/Taurine.app\n' "$PWD"
