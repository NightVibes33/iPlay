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

echo "[0/6] Verify single upstream settings surface"
python3 - "$SRC/iPlay.m" "$SRC/upstream_ui.inc" "$SRC/local_carkit.m" "$SRC/carplay_services.m" "$SRC/SideStoreBridge.m" <<'PY'
from pathlib import Path
import re
import sys

main = Path(sys.argv[1]).read_text()
home = Path(sys.argv[2]).read_text()
local_carkit = Path(sys.argv[3]).read_text()
carplay_services = Path(sys.argv[4]).read_text()
sidestore_bridge = Path(sys.argv[5]).read_text()

definitions = re.findall(r"(?m)^- \(void\)showUpstreamSettings\s*\{", main)
if len(definitions) != 1:
    raise SystemExit(f"expected exactly one showUpstreamSettings implementation, found {len(definitions)}")

if "showUpstreamSettingsReal" in main or "showUpstreamSettingsReal" in home:
    raise SystemExit("obsolete duplicate showUpstreamSettingsReal path returned")

if "showUpstreamSettings" in home:
    raise SystemExit("upstream_ui.inc must not define a second settings surface")

for obsolete in (
    "showUpstreamConnectionSetupFrom",
    "showUpstreamAboutPageFrom",
    "upstreamPageControllerWithBack",
    "upstreamSectionWithTitle",
):
    if obsolete in home:
        raise SystemExit(f"obsolete duplicate-settings helper returned: {obsolete}")

def method_body(name: str) -> str:
    marker = f"- (void){name}"
    start = main.find(marker)
    if start < 0:
        raise SystemExit(f"missing {name} entry point")
    next_method = main.find("\n- (", start + len(marker))
    return main[start:] if next_method < 0 else main[start:next_method]

for entry in ("tertiaryTapped", "toggleChrome:"):
    if "[self showUpstreamSettings]" not in method_body(entry):
        raise SystemExit(f"{entry} no longer routes to the shared upstream settings surface")

if main.count('#include "upstream_ui.inc"') != 1:
    raise SystemExit("upstream_ui.inc must be included exactly once")

settings_start = main.find("- (void)showUpstreamSettings {")
settings_end = main.find('#include "upstream_ui.inc"', settings_start)
if settings_start < 0 or settings_end <= settings_start:
    raise SystemExit("unable to isolate shared settings implementation")
settings_body = main[settings_start:settings_end]
runtime_source = (
    main[:settings_start] + main[settings_end:] +
    local_carkit + carplay_services + sidestore_bridge
)

if re.search(r"\.enabled\s*=\s*NO|setEnabled\s*:\s*NO|action\s*:\s*nil", settings_body):
    raise SystemExit("shared settings contains a disabled or nil-action placeholder control")

runtime_keys = (
    "iPlayAutoConnect", "iPlayAutoForeground",
    "iPlayPhysicalWidthMm", "iPlayPhysicalSizeBasis",
    "iPlayDisplayScaleTenths", "iPlayFrameRate", "iPlayMusicBufferMs",
    "iPlayHEVC", "iPlayRightHandDrive", "iPlayFullScreen",
    "iPlayAudioFocus", "iPlayLocationReport", "iPlayDebugLogs",
    "iPlayManufacturer", "iPlayModel", "iPlayOEMLabel",
    "iPlaySafeLeftPm", "iPlaySafeTopPm", "iPlaySafeRightPm",
    "iPlaySafeBottomPm", "iPlaySafeDrawOutside",
    "iPlayRemoteReceiverName", "iPlayRemoteReceiverHost",
    "iPlayRemoteReceiverPort",
)
indirect_ui_keys = {
    # The visible send-target control invokes the receiver picker; the picker
    # owns the selected endpoint's port and persists it outside this method.
    "iPlayRemoteReceiverPort",
}
for key in runtime_keys:
    # One occurrence is the trackedKeys rollback snapshot. Direct controls
    # must have at least one additional UI read/write.
    if key not in indirect_ui_keys and settings_body.count(key) < 2:
        raise SystemExit(f"expected real settings control/key is missing from shared surface: {key}")
    if key not in runtime_source:
        raise SystemExit(f"settings key has no runtime consumer outside the UI: {key}")

if "chooseRemoteAtoBReceiverFrom:settings" not in settings_body:
    raise SystemExit("remote receiver port lost its live send-target chooser")

# Lock the remaining upstream interaction types: driving side is a two-choice
# selector, Safe area uses the full-screen draggable-boundary editor, and
# active X restores the baseline then starts a fresh handshake.
if "UISegmentedControl *drivingSide" not in settings_body or "rhdSwitch" in settings_body:
    raise SystemExit("driving-side control drifted from upstream two-choice selector")

if "IPlaySafeAreaEditorView" not in main:
    raise SystemExit("upstream visual safe-area editor is missing")
if "safeSliders" in settings_body or "safeEditorRows" in settings_body:
    raise SystemExit("obsolete inline safe-area slider substitute returned")

close_match = re.search(
    r"\[close addAction:.*?BOOL reconnect = \(self\.state == StateActive\);.*?"
    r"restoreBaseline\(\);.*?restartWhenIdleForMode:mode attemptsRemaining:100",
    settings_body,
    flags=re.S,
)
if not close_match:
    raise SystemExit("active settings X no longer rolls back and reconnects like upstream")

# Lock the iOS runtime to DiPlay's upstream display defaults. Missing or
# invalid stored values must resolve to 60 FPS and a 200 mm reference length.
if not re.search(
    r"if \(requestedFPS < 30 \|\| requestedFPS > 60\)\s*requestedFPS = 60;",
    main,
):
    raise SystemExit("runtime FPS fallback drifted from upstream default 60 FPS")

if not re.search(
    r"if \(referencePhysicalMm < 100 \|\| referencePhysicalMm > 400\)\s*referencePhysicalMm = 200;",
    main,
):
    raise SystemExit("runtime physical-length fallback drifted from upstream default 200 mm")

if "static uint16_t g_display_fps = 60;" not in carplay_services:
    raise SystemExit("receiver FPS default drifted from upstream default 60 FPS")

if "static uint16_t g_display_width_physical_mm = 200;" not in carplay_services:
    raise SystemExit("receiver physical-length default drifted from upstream default 200 mm")

if "socketpair(AF_UNIX, SOCK_STREAM, 0, pair)" not in main:
    raise SystemExit("SideStore direct in-process socketpair IPC is missing")
if "iPlayCarPlayServiceSetAppSocket(pair[1])" not in main:
    raise SystemExit("SideStore socketpair service end is not transferred to the receiver")
if "void iPlayCarPlayServiceSetAppSocket(int fd)" not in carplay_services:
    raise SystemExit("receiver cannot accept a fresh in-process IPC channel")
if "iPlayCarPlayServiceSetAppPort(self.ipcPort)" not in main:
    raise SystemExit("loopback fallback port is not handed to an already-running receiver")
if "void iPlayCarPlayServiceSetAppPort(uint16_t port)" not in carplay_services:
    raise SystemExit("receiver cannot accept a live fallback IPC port")
if "IPC listening on 127.0.0.1:" in main:
    raise SystemExit("obsolete SideStore loopback listener returned")

for source, filename in (
    (main, "iPlay.m"),
    (local_carkit, "local_carkit.m"),
    (carplay_services, "carplay_services.m"),
):
    if 'stringByAppendingPathComponent:@"iPlay Logs"' not in source:
        raise SystemExit(f"Files-visible iPlay Logs path missing from {filename}")

print("single upstream settings surface, runtime-backed controls, defaults, IPC, and Files logs verified")
PY

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
APP="$OUT/Payload/iPlay.app"
cp "$SRC/Info.plist" "$APP/Info.plist"

# A real launch storyboard opts modern iPhones out of legacy 3:2 compatibility
# letterboxing before UIKit lays out the upstream surface.
xcrun ibtool --compile "$APP/LaunchScreen.storyboardc" "$SRC/LaunchScreen.storyboard"

# Use upstream DiPlay's original launcher artwork as the installed app icon.
# Generate the concrete iPhone/iPad icon sizes expected by the legacy
# CFBundleIconFiles metadata so sideloaded builds do not show a blank icon.
ICON_SRC="$ROOT/shared/src/main/ic_launcher-playstore.png"
test -s "$ICON_SRC"
sips -z 60 60   "$ICON_SRC" --out "$APP/AppIcon60x60.png" >/dev/null
sips -z 120 120 "$ICON_SRC" --out "$APP/AppIcon60x60@2x.png" >/dev/null
sips -z 180 180 "$ICON_SRC" --out "$APP/AppIcon60x60@3x.png" >/dev/null
sips -z 76 76   "$ICON_SRC" --out "$APP/AppIcon76x76.png" >/dev/null
sips -z 152 152 "$ICON_SRC" --out "$APP/AppIcon76x76@2x.png" >/dev/null
sips -z 167 167 "$ICON_SRC" --out "$APP/AppIcon83.5x83.5@2x.png" >/dev/null

# Use the exact upstream DiPlay CarPlay artwork in the UIKit port.
cp "$ROOT/common/src/main/res/drawable/ic_carplay.png" "$APP/ic_carplay.png"
cp "$ROOT/common/src/main/res/raw/ic_car_home.png" "$APP/ic_car_home.png"
chmod +x "$APP/iPlay"

# Packaging invariants for modern full-screen presentation and the installed
# icon. Fail CI rather than shipping another letterboxed/iconless IPA.
test -d "$APP/LaunchScreen.storyboardc"
test -s "$APP/AppIcon60x60@2x.png"
test -s "$APP/AppIcon60x60@3x.png"
test "$(/usr/libexec/PlistBuddy -c 'Print :UILaunchStoryboardName' "$APP/Info.plist")" = "LaunchScreen"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0' "$APP/Info.plist" | grep -qx 'AppIcon60x60'

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
