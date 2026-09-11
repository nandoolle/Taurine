#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TAURINE_SIGN_IDENTITY="${1-${TAURINE_SIGN_IDENTITY-}}"
if [ -z "$TAURINE_SIGN_IDENTITY" ]; then
    printf 'uso: %s "Developer ID Application: Nome (TEAMID)"\n' "$0" >&2
    printf '     (ou defina TAURINE_SIGN_IDENTITY no ambiente)\n\n' >&2
    printf 'identidades disponíveis:\n' >&2
    /usr/bin/security find-identity -v -p codesigning >&2
    exit 1
fi
: "${TAURINE_NOTARY_PROFILE:=taurine-notary}"

export TAURINE_SIGN_IDENTITY
rm -rf build/Taurine.app
./scripts/build.sh

app="build/Taurine.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")

# O helper é código aninhado num diretório que o codesign do app não percorre:
# verificar o bundle não prova que ele tem hardened runtime e timestamp.
/usr/bin/codesign --verify --strict --deep "$app"
for target in "$app" "$app/Contents/Library/LaunchDaemons/dev.taurine.helper"; do
    info=$(/usr/bin/codesign -dv --verbose=4 "$target" 2>&1)
    grep -q 'CodeDirectory .*flags=.*runtime' <<<"$info" || { printf 'error: sem hardened runtime: %s\n' "$target" >&2; exit 1; }
    grep -q '^Timestamp=' <<<"$info" || { printf 'error: sem timestamp seguro: %s\n' "$target" >&2; exit 1; }
done

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto -c -k --keepParent "$app" "$staging/Taurine.zip"
xcrun notarytool submit "$staging/Taurine.zip" --keychain-profile "$TAURINE_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"

# DMG é construído a partir do app já stapled, e notarizado por si: sem isto o
# app instalado depende de consulta online ao Gatekeeper no primeiro launch.
dmg="build/Taurine-$version.dmg"
dmg_staging=$(mktemp -d)
trap 'rm -rf "$staging" "$dmg_staging"' EXIT
/usr/bin/ditto "$app" "$dmg_staging/Taurine.app"
ln -s /Applications "$dmg_staging/Applications"
# Um .DS_Store herdado faz o Finder considerar o layout já definido e ignorar o
# AppleScript abaixo. O volume precisa começar sem ele.
rm -f "$dmg_staging/.DS_Store"
rm -f "$dmg"

# O layout da janela (tamanho dos ícones, posições) vive no .DS_Store do volume,
# então o DMG precisa ser montado gravável e ajustado antes de comprimir.
writable="$dmg_staging.rw.dmg"
volume="Taurine $version"
hdiutil create -volname "$volume" -srcfolder "$dmg_staging" -ov -format UDRW "$writable" >/dev/null
mountpoint=$(hdiutil attach "$writable" -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)
trap 'hdiutil detach "$mountpoint" >/dev/null 2>&1 || true; rm -rf "$staging" "$dmg_staging" "$writable"' EXIT

/usr/bin/osascript - "$volume" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            -- 660x420: cabe os dois ícones a 128pt com folga, sem janela vazia.
            set the bounds of container window to {200, 160, 860, 580}
            set options to the icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 128
            set text size of options to 13
            set position of item "Taurine.app" of container window to {170, 190}
            set position of item "Applications" of container window to {470, 190}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

# O Finder grava o .DS_Store de forma assíncrona: sem esperar pelo arquivo, o
# layout se perde e o DMG sai com a janela padrão. Limpeza só depois disso.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$mountpoint/.DS_Store" ] && break
    sleep 1
done
[ -s "$mountpoint/.DS_Store" ] || { printf 'error: Finder não gravou o layout da janela (.DS_Store)\n' >&2; exit 1; }

# O Finder cria .fseventsd em qualquer volume gravável; no DMG final é só lixo.
rm -rf "$mountpoint/.fseventsd" "$mountpoint/.Trashes" "$mountpoint/.TemporaryItems"

# sync antes do detach: o .DS_Store é escrito de forma assíncrona pelo Finder.
sync
hdiutil detach "$mountpoint" >/dev/null
trap 'rm -rf "$staging" "$dmg_staging" "$writable"' EXIT
hdiutil convert "$writable" -format UDZO -imagekey zlib-level=9 -o "$dmg" >/dev/null
# Ícone do .dmg no Finder. Precisa vir antes do codesign: o ícone vive num fork
# do arquivo, e gravá-lo depois invalidaria a assinatura.
if [ -f assets/dmg-icon.icns ]; then
    icon_tool="$(mktemp -d)/set-file-icon"
    /usr/bin/xcrun swiftc -O scripts/set-file-icon.swift -o "$icon_tool"
    "$icon_tool" "$dmg" assets/dmg-icon.icns
fi

/usr/bin/codesign --force --timestamp --sign "$TAURINE_SIGN_IDENTITY" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$TAURINE_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"

xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
/usr/sbin/spctl -a -vvv -t exec "$app"
/usr/sbin/spctl -a -vvv -t open --context context:primary-signature "$dmg"
printf '\nReleased: %s/%s\n' "$PWD" "$dmg"
