# OpenGlass

An open-source iOS companion app for **Meta Ray-Ban Stories gen 1** smart glasses. Fully replaces the official Meta AI app — no Meta cloud, no Meta account, no ongoing dependency.

## What it does

- **Independent BLE connection** — connects directly to your glasses over Bluetooth using the reverse-engineered DataX protocol
- **RSA+AES authentication** — full PhaseB handshake (RSA-OAEP + AES-256-GCM) with identity extracted once from the Meta AI app
- **Media transfer** — downloads stored photos and videos from the glasses via SoftAP (the glasses' built-in Wi-Fi access point)
- **Local storage** — saves captures with SwiftData, exports to the iOS Photos library
- **Gallery** — grid view of downloaded media
- **Dashboard** — scan, connect, authenticate, and view device info (battery, firmware, serial)
- **Delete Meta AI** — after one-time key extraction, the Meta AI app can be removed permanently

## How it works

The glasses use a proprietary BLE protocol over a single GATT characteristic. OpenGlass implements the full protocol stack:

1. **BLE scanning** — finds "RB Stories" devices via the Meta service UUID (`0xFD5F`)
2. **GATT connection** — subscribes to the DataX characteristic for all command/response traffic
3. **PhaseB authentication** — 4-step handshake using your extracted RSA key and bootstrap ticket
4. **Encrypted commands** — AES-256-GCM with 96-bit truncated tags over the DataX channel
5. **SoftAP media download** — triggers the glasses' Wi-Fi AP, connects, and downloads over HTTPS

## Requirements

- iOS 17.2+
- Xcode 26.4+ (Swift 6.3)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Meta Ray-Ban Stories gen 1 glasses
- One-time access to the Meta AI app for key extraction (then delete it)

## First-time setup

### 1. Extract your identity (one time only)

You need to extract your RSA private key and bootstrap ticket from the Meta AI app. This requires:

- A Mac with Frida installed (`pip install frida-tools`)
- A FairPlay-decrypted copy of the Meta AI IPA (use bagbak, frida-ios-dump, or CrackerXI+)
- Your Apple developer certificate for re-signing

Steps:

1. Inject `FridaGadget.dylib` into the decrypted Meta AI IPA
2. Re-sign and sideload via AltStore
3. Connect your iPhone to your Mac via USB
4. Run: `frida -U "Meta AI" -l tools/extract_keys.js`
5. In the patched app, unpair and re-pair your glasses
6. Copy the printed `RSA_KEY_HEX` and `TICKET_HEX` values

### 2. Import into OpenGlass

1. Open OpenGlass > Settings > Import Identity
2. Paste the RSA key hex and bootstrap ticket hex
3. Tap Import

### 3. Connect

1. Go to Dashboard > Scan for Glasses
2. Tap your glasses when they appear
3. Tap Authenticate

Done. Delete the Meta AI app.

## Build

```bash
brew install xcodegen
xcodegen generate
open OpenGlass.xcodeproj
```

Or build from CLI:

```bash
xcodebuild archive \
  -project OpenGlass.xcodeproj \
  -scheme OpenGlass \
  -configuration Release \
  -archivePath build/OpenGlass.xcarchive \
  -destination "generic/platform=iOS" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
```

## Sideloading

Install the unsigned `.ipa` with:

- **AltStore** — drag the .ipa (7-day refresh with free Apple ID)
- **Sideloadly** — connect via USB and sideload
- **TrollStore** — if supported, install directly

## Project structure

```
Sources/
  App/            — SwiftUI app entry, GlassesController, root views
  Bluetooth/      — CoreBluetooth wrapper, GATT constants, DataX framing
  Crypto/         — AES-256-GCM, RSA-OAEP, PhaseB handshake, identity keychain
  MediaTransfer/  — SoftAP Wi-Fi management, HTTPS media downloads
  Models/         — Observable glasses state, capture metadata, SwiftData models
  Storage/        — Local file management, Photos export
  UI/             — Dashboard, Gallery, Settings, ConnectionButton
tools/
  extract_keys.js — Frida script for one-time key extraction
```

## Privacy

Everything stays on your iPhone. OpenGlass communicates directly with the glasses over Bluetooth and Wi-Fi — no cloud, no telemetry, no Meta servers. Your RSA key and bootstrap ticket are stored in the iOS Keychain, encrypted at rest.

## License

MIT. See [LICENSE](LICENSE).
