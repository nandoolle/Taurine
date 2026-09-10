#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
identity="${TAURINE_SIGN_IDENTITY-}"
# Sem Developer ID o helper precisa do -DTAURINE_ADHOC: senão ele exige uma
# assinatura que o app ad-hoc não tem e a conexão XPC morre sem diagnóstico.
if [ -n "$identity" ]; then
    conditions=()
else
    conditions=(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) TAURINE_ADHOC')
fi
xcodebuild -project src/Taurine.xcodeproj -scheme Taurine \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO \
    "${conditions[@]+"${conditions[@]}"}" build
mkdir -p build
/usr/bin/ditto .build/xcode/Build/Products/Release/Taurine.app build/Taurine.app
cp LICENSE build/Taurine.app/Contents/Resources/
if [ -n "$identity" ]; then
    sign_flags=(--force --options runtime --timestamp --sign "$identity")
else
    sign_flags=(--force --sign -)
    printf 'warning: assinando ad-hoc (defina TAURINE_SIGN_IDENTITY para Developer ID)\n' >&2
fi
/usr/bin/codesign "${sign_flags[@]}" --identifier dev.taurine.helper build/Taurine.app/Contents/Library/LaunchDaemons/dev.taurine.helper
/usr/bin/codesign "${sign_flags[@]}" build/Taurine.app
/usr/bin/codesign --verify --strict build/Taurine.app
printf '\nBuilt: %s/build/Taurine.app\n' "$PWD"
