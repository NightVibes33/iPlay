# iPlay iOS / SideStore head-unit port

Temporary branch: `temp/ios-carplay-headunit`

This branch adds an **unsigned iOS IPA target** to the DiPlay fork and imports the working GPL-3.0
Showcase receiver implementation as the iOS receiver core.

### Included now

- AirPlay/CarPlay mDNS + RTSP receiver
- HomeKit-style SRP pair-setup
- X25519/Ed25519 pair-verify
- encrypted control and event channels
- BAA/MFi authentication path
- H.264 CarPlay screen stream decryption
- audio stream handling
- touch/HID return path
- sandbox-local app/service IPC
- experimental display negotiation up to 120 FPS
- runtime BluetoothManager private-framework capability probe
- unsigned SideStore IPA CI artifact

### Target modes

- **A -> B:** iPhone B runs iPlay as the head-unit receiver.
- **A -> A:** same receiver core with a future local/virtual bootstrap instead of physical Bluetooth/Wi-Fi handoff.

The original Showcase Bluetooth takeover uses a jailbreak BTstack daemon. That part is intentionally
separated from the receiver stack here so the SideStore port can replace it rather than pretending a
normal SideStore sandbox has root HCI access.

### Build

```bash
bash scripts/build-ios-unsigned.sh
```

Output: `build-ios/iPlay-unsigned.ipa`

The script deliberately performs **no signing**. SideStore signs the IPA during installation.
