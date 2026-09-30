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

echo "[1/4] Compile embedded CarPlay receiver"
"$CLANG" "${COMMON[@]}" -fobjc-arc -Dmain=iPlayCarPlayServiceMain   -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath"   -c "$SRC/carplay_services.m" -o "$OUT/carplay_services.o"

"$CLANG" "${COMMON[@]}"   -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath"   -c "$SRC/carplay_pair.c" -o "$OUT/carplay_pair.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/monocypher"   -c "$SRC/vendor/monocypher/monocypher.c" -o "$OUT/monocypher.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/monocypher"   -c "$SRC/vendor/monocypher/monocypher-ed25519.c" -o "$OUT/monocypher-ed25519.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/libtommath"   -c "$SRC/vendor/libtommath/tommath.c" -o "$OUT/tommath.o"

echo "[2/4] Link iPlay + receiver into one SideStore executable"
"$CLANG" "${COMMON[@]}" -fobjc-arc   "$SRC/iPlay.m" "$SRC/SideStoreBridge.m"   "$OUT/carplay_services.o" "$OUT/carplay_pair.o"   "$OUT/monocypher.o" "$OUT/monocypher-ed25519.o" "$OUT/tommath.o"   -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath"   -o "$OUT/Payload/iPlay.app/iPlay"   -framework UIKit -framework AVFoundation -framework AudioToolbox   -framework CoreMedia -framework Foundation -framework Security   -framework QuartzCore -framework CoreVideo -framework VideoToolbox   -Wl,-undefined,dynamic_lookup

echo "[3/4] Assemble unsigned app"
cp "$SRC/Info.plist" "$OUT/Payload/iPlay.app/Info.plist"
chmod +x "$OUT/Payload/iPlay.app/iPlay"

# Deliberately no codesign/ldid. SideStore signs at installation.
if codesign -dv "$OUT/Payload/iPlay.app/iPlay" >/dev/null 2>&1; then
  echo "ERROR: main binary unexpectedly contains a code signature" >&2
  exit 1
fi
test ! -e "$OUT/Payload/iPlay.app/_CodeSignature"
test ! -e "$OUT/Payload/iPlay.app/embedded.mobileprovision"

echo "[4/4] Package unsigned IPA"
(
  cd "$OUT"
  /usr/bin/zip -qry iPlay-unsigned.ipa Payload
)
echo "Built: $OUT/iPlay-unsigned.ipa"
