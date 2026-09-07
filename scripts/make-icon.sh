#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
mkdir -p .build/Taurine.iconset
swift scripts/make-icon.swift .build/Taurine-icon.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/Taurine-icon.png --out ".build/Taurine.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/Taurine-icon.png --out ".build/Taurine.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# ICNS PNG elements; avoids depending on the Xcode/IconServices converter.
python3 - <<'PY'
from pathlib import Path
import struct
entries = [('icp4','16x16'), ('icp5','32x32'), ('icp6','32x32@2x'),
           ('ic07','128x128'), ('ic08','256x256'), ('ic09','512x512'),
           ('ic10','512x512@2x'), ('ic11','16x16@2x'), ('ic12','32x32@2x'),
           ('ic13','128x128@2x'), ('ic14','256x256@2x')]
chunks = []
for kind,name in entries:
    image = Path(f'.build/Taurine.iconset/icon_{name}.png').read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(image)+8) + image)
body = b''.join(chunks)
Path('src/Taurine/Resources/Taurine.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
PY
