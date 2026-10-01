#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/iOS/SideStoreReceiver"
OUT="$ROOT/build-ios"

# Hosted runners can inherit a literal/dead DEVELOPER_DIR from upstream scripts.
# Resolve the active Xcode installation before any xcrun or Cargo invocation.
export DEVELOPER_DIR="$(xcode-select -p)"
unset SDKROOT || true
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
TARGET="arm64-apple-ios16.0"
AIRCARD_REV="097a058c984ffc33ccb697b9dfe8058be3e86244"

rm -rf "$OUT"
mkdir -p "$OUT/Payload/iPlay.app"

COMMON=(-target "$TARGET" -isysroot "$SDK" -miphoneos-version-min=16.0 -O2)

echo "[1/6] Build embedded LocalDevVPN / trusted-RSD core"
AIRCARD="$OUT/AirCard-iOS"
git clone --quiet https://github.com/Mak5er/AirCard-iOS.git "$AIRCARD"
git -C "$AIRCARD" checkout --quiet --detach "$AIRCARD_REV"
cp "$SRC/carkit_proxy.rs" "$AIRCARD/rust-core/src/carkit_proxy.rs"

python3 - "$AIRCARD/rust-core/src/lib.rs" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if "pub mod carkit_proxy;" not in s:
    s = s.replace("pub mod exploit;\n", "pub mod exploit;\npub mod carkit_proxy;\n", 1)
anchor = """// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------
"""
ffi = r"""// ---------------------------------------------------------------------------
// LocalDevVPN / trusted CarKit proxy
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn al_carkit_proxy_run(
    pairing_path: *const c_char,
    local_port: u16,
    log_cb: carkit_proxy::ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        carkit_proxy::run_proxy(pairing_path, local_port, log_cb, ctx, out_error)
    }));
    match res {
        Ok(rc) => rc,
        Err(e) => {
            if !out_error.is_null() {
                *out_error = ffi_util::cstr(format!("Rust panic in al_carkit_proxy_run: {e:?}"));
            }
            1
        }
    }
}

"""
if "al_carkit_proxy_run" not in s:
    s = s.replace(anchor, ffi + anchor, 1)
p.write_text(s)
PY

export IPHONEOS_DEPLOYMENT_TARGET=16.0
source "$HOME/.cargo/env" 2>/dev/null || true
rustup target add aarch64-apple-ios
(
  cd "$AIRCARD/rust-core"
  cargo build --release --target aarch64-apple-ios
)
cp "$AIRCARD/rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a" "$OUT/libairlift_ffi.a"

echo "[2/6] Compile embedded CarPlay receiver"
"$CLANG" "${COMMON[@]}" -fobjc-arc -Dmain=iPlayCarPlayServiceMain \
  -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath" \
  -c "$SRC/carplay_services.m" -o "$OUT/carplay_services.o"

"$CLANG" "${COMMON[@]}" \
  -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath" \
  -c "$SRC/carplay_pair.c" -o "$OUT/carplay_pair.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/monocypher" \
  -c "$SRC/vendor/monocypher/monocypher.c" -o "$OUT/monocypher.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/monocypher" \
  -c "$SRC/vendor/monocypher/monocypher-ed25519.c" -o "$OUT/monocypher-ed25519.o"

"$CLANG" "${COMMON[@]}" -I"$SRC/vendor/libtommath" \
  -c "$SRC/vendor/libtommath/tommath.c" -o "$OUT/tommath.o"

echo "[3/6] Compile LocalDevVPN CarKit / wired-iAP2 bridge"
"$CLANG" "${COMMON[@]}" -fobjc-arc \
  -I"$SRC" \
  -c "$SRC/local_carkit.m" -o "$OUT/local_carkit.o"

echo "[4/6] Link iPlay + receiver + LocalDevVPN core into one SideStore executable"
"$CLANG" "${COMMON[@]}" -fobjc-arc \
  "$SRC/iPlay.m" "$SRC/SideStoreBridge.m" \
  "$OUT/local_carkit.o" \
  "$OUT/carplay_services.o" "$OUT/carplay_pair.o" \
  "$OUT/monocypher.o" "$OUT/monocypher-ed25519.o" "$OUT/tommath.o" \
  "$OUT/libairlift_ffi.a" \
  -I"$SRC" -I"$SRC/vendor/monocypher" -I"$SRC/vendor/libtommath" \
  -o "$OUT/Payload/iPlay.app/iPlay" \
  -framework UIKit -framework AVFoundation -framework AudioToolbox \
  -framework CoreMedia -framework Foundation -framework Security -framework CoreLocation \
  -framework PhotosUI \
  -framework QuartzCore -framework CoreVideo -framework VideoToolbox \
  -lc++ -Wl,-undefined,dynamic_lookup

echo "[5/6] Assemble unsigned app"
cp "$SRC/Info.plist" "$OUT/Payload/iPlay.app/Info.plist"
# Use the exact upstream DiPlay CarPlay artwork in the UIKit port.
cp "$ROOT/common/src/main/res/drawable/ic_carplay.png" "$OUT/Payload/iPlay.app/ic_carplay.png"
chmod +x "$OUT/Payload/iPlay.app/iPlay"

if codesign -dv "$OUT/Payload/iPlay.app/iPlay" >/dev/null 2>&1; then
  echo "ERROR: main binary unexpectedly contains a code signature" >&2
  exit 1
fi
test ! -e "$OUT/Payload/iPlay.app/_CodeSignature"
test ! -e "$OUT/Payload/iPlay.app/embedded.mobileprovision"

echo "[6/6] Package unsigned IPA"
(
  cd "$OUT"
  /usr/bin/zip -qry iPlay-unsigned.ipa Payload
)
echo "Built: $OUT/iPlay-unsigned.ipa"
