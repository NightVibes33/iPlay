#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/iOS/SideStoreReceiver"
OUT="$ROOT/build-ios"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
TARGET="arm64-apple-ios16.0"

rm -rf "$OUT"
mkdir -p "$OUT/Payload/iPlay.app"

COMMON=(-target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=16.0 -O2)

echo "[1/4] Compile iPlay"
"$CLANG" "${COMMON[@]}" -fobjc-arc   "$SRC/iPlay.m" "$SRC/SideStoreBridge.m"   -I"$SRC"   -o "$OUT/Payload/iPlay.app/iPlay"   -framework UIKit -framework AVFoundation -framework AudioToolbox   -framework CoreMedia -framework Foundation -framework Security   -framework QuartzCore -framework CoreVideo -framework VideoToolbox   -Wl,-undefined,dynamic_lookup

echo "[2/4] Compile CarPlay receiver service"
"$CLANG" "${COMMON[@]}" -fobjc-arc   "$SRC/carplay_services.m" "$SRC/carplay_pair.c"   "$SRC/vendor/monocypher/monocypher.c"   "$SRC/vendor/monocypher/monocypher-ed25519.c"   "$SRC/vendor/libtommath/tommath.c"   -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath"   -o "$OUT/Payload/iPlay.app/carplay_services"   -framework Foundation -framework Security   -Wl,-undefined,dynamic_lookup

echo "[3/4] Assemble unsigned app"
cp "$SRC/Info.plist" "$OUT/Payload/iPlay.app/Info.plist"
chmod +x "$OUT/Payload/iPlay.app/iPlay" "$OUT/Payload/iPlay.app/carplay_services"

# No codesign or ldid: SideStore signs at install time.
if codesign -dv "$OUT/Payload/iPlay.app/iPlay" >/dev/null 2>&1; then
  echo "ERROR: main binary unexpectedly contains a signature" >&2
  exit 1
fi

echo "[4/4] Package IPA"
(
  cd "$OUT"
  /usr/bin/zip -qry iPlay-unsigned.ipa Payload
)

echo "Built: $OUT/iPlay-unsigned.ipa"
