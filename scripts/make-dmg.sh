#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d build/Taurine.app ] || ./scripts/build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/Taurine.app/Contents/Info.plist)
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto build/Taurine.app "$staging/Taurine.app"
ln -s /Applications "$staging/Applications"
output="build/Taurine-$version.dmg"
rm -f "$output"
hdiutil create -volname "Taurine $version" -srcfolder "$staging" -ov -format UDZO "$output" >/dev/null
printf 'Built: %s/%s\n' "$PWD" "$output"
