#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
parts_dir = Path(sys.argv[2])
src = root / "rust-core" / "src"
exploit = src / "exploit.rs"
lib = src / "lib.rs"
module_dest = src / "iplay_carkit.rs"

text = exploit.read_text()
repls = [
    ("struct Logger {", "pub(crate) struct Logger {"),
    ("    cb: ALLogCallback,\n    ctx: *mut c_void,", "    pub(crate) cb: ALLogCallback,\n    pub(crate) ctx: *mut c_void,"),
    ("    fn log(&self, msg: impl AsRef<str>) {", "    pub(crate) fn log(&self, msg: impl AsRef<str>) {"),
    ("enum AppDeviceTunnel {", "pub(crate) enum AppDeviceTunnel {"),
    ("    async fn connect_service(&mut self, service_base: &str, logger: &Logger) -> Result<Box<dyn ReadWrite>, String> {", "    pub(crate) async fn connect_service(&mut self, service_base: &str, logger: &Logger) -> Result<Box<dyn ReadWrite>, String> {"),
    ("async fn connect_tunnel(pairing_bytes: &[u8], logger: &Logger) -> Result<AppDeviceTunnel, String> {", "pub(crate) async fn connect_tunnel(pairing_bytes: &[u8], logger: &Logger) -> Result<AppDeviceTunnel, String> {"),
]
for old, new in repls:
    if old not in text:
        raise SystemExit(f"AirCard patch marker missing: {old}")
    text = text.replace(old, new, 1)
exploit.write_text(text)

lib_text = lib.read_text()
marker = "pub mod pairing;"
if marker not in lib_text:
    raise SystemExit("AirCard lib.rs marker missing")
lib_text = lib_text.replace(marker, marker + "\npub mod iplay_carkit;", 1)
lib.write_text(lib_text)

parts = sorted(parts_dir.glob("iplay_carkit.part*.rs"))
if not parts:
    raise SystemExit("iPlay CarKit Rust parts missing")
module_dest.write_text("".join(p.read_text() for p in parts))
print("patched AirCard rust-core for iPlay LocalDevVPN CarKit A->A")
