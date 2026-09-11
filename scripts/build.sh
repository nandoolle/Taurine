#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
mkdir -p .build/app build
# SMAppService recusa assinatura ad-hoc no register(), então Developer ID é
# obrigatório — inclusive para desenvolvimento local. Notarização não: só
# distribuição precisa dela.
identity="${TAURINE_SIGN_IDENTITY-}"
if [ -z "$identity" ]; then
    printf 'error: defina TAURINE_SIGN_IDENTITY com sua Developer ID Application.\n' >&2
    printf '       ex: export TAURINE_SIGN_IDENTITY="Developer ID Application: Nome (TEAMID)"\n' >&2
    printf '       identidades disponíveis:\n' >&2
    /usr/bin/security find-identity -v -p codesigning >&2 || true
    exit 1
fi
# Sem --timestamp: exige rede e o SMAppService não o pede. release.sh o adiciona.
sign_flags=(--force --options runtime --sign "$identity")

compiler="$(/usr/bin/xcrun --find swiftc)"
developer_dir="$(/usr/bin/xcode-select -p)"
sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -d "$sdk" ]; then sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"; fi
shared_sources=(src/TaurineShared/*.swift)
helper_sources=(src/TaurineHelper/Sources/*.swift)
app_sources=(src/Taurine/Classes/*.swift src/Taurine/Classes/*/*.swift)
common=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.6" -sdk "$sdk" -module-cache-path "$SWIFT_MODULECACHE_PATH")

"$compiler" "${common[@]}" -parse-as-library -module-name TaurineShared \
    -emit-module -emit-module-path .build/app/TaurineShared.swiftmodule \
    -emit-library -static -o .build/app/libTaurineShared.a "${shared_sources[@]}"

"$compiler" "${common[@]}" -parse-as-library -module-name TaurineHelper \
    -I .build/app -L .build/app -lTaurineShared \
    "${helper_sources[@]}" -o .build/app/dev.taurine.helper

"$compiler" "${common[@]}" -parse-as-library -default-isolation MainActor -module-name Taurine \
    -I .build/app -L .build/app -lTaurineShared \
    "${app_sources[@]}" -o .build/app/Taurine
app="build/Taurine.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p "$app/Contents/Library/LaunchDaemons"
cp .build/app/dev.taurine.helper "$app/Contents/Library/LaunchDaemons/dev.taurine.helper"
cp src/TaurineHelper/Resources/dev.taurine.helper.plist "$app/Contents/Library/LaunchDaemons/"
/usr/bin/codesign "${sign_flags[@]}" --identifier dev.taurine.helper "$app/Contents/Library/LaunchDaemons/dev.taurine.helper"
cp .build/app/Taurine "$app/Contents/MacOS/Taurine.new"
mv -f "$app/Contents/MacOS/Taurine.new" "$app/Contents/MacOS/Taurine"
cp src/Taurine/Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Taurine' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.taurine.app' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Taurine' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.5.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 8' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDevelopmentRegion string en' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.6' "$app/Contents/Info.plist"
cp -R src/Taurine/Resources/*.lproj "$app/Contents/Resources/"
cp src/Taurine/Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
cp src/Taurine/Resources/Assets.xcassets/active.imageset/active@2x.png "$app/Contents/Resources/"
cp src/Taurine/Resources/Assets.xcassets/inactive.imageset/inactive@2x.png "$app/Contents/Resources/"
cp src/Taurine/Resources/can-opening.wav "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/"
cp src/Taurine/Resources/Taurine.icns "$app/Contents/Resources/"
/usr/bin/codesign "${sign_flags[@]}" "$app"
/usr/bin/codesign --verify --strict "$app"
printf '\nBuilt: %s/%s\n' "$PWD" "$app"
