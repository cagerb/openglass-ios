# OpenGlass

An open-source iOS companion app for **Meta Ray-Ban Stories gen 1** smart glasses. Replaces the official Meta AI app with full local control over your glasses.

## What it does

- **Bluetooth control** — connects to your glasses over BLE (service `0xFD5F`), reads battery, firmware, and device info
- **Authenticated session** — full PhaseB handshake (RSA-OAEP + AES-256-GCM) for encrypted communication
- **Media transfer** — joins the glasses' SoftAP Wi-Fi, downloads photos and videos over HTTPS
- **Local storage** — saves captures with SwiftData, exports to the iOS Photos library
- **Gallery** — grid view of captures with thumbnails, tap to download full-resolution
- **Dashboard** — live battery, storage, temperature, and device status

## Requirements

- iOS 17.0+
- Xcode 15.4+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the `.xcodeproj`)
- Meta Ray-Ban Stories gen 1 glasses with a bootstrap ticket

## Build

```bash
# Install XcodeGen if you haven't
brew install xcodegen

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open OpenGlass.xcodeproj

# Or build from the command line (unsigned, for sideloading)
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

The GitHub Actions workflow produces an unsigned `.ipa` on every push to `main`. Download it from the Actions tab and install with:

- **AltStore** — drag the `.ipa` into AltStore
- **Sideloadly** — connect your iPhone and sideload
- **TrollStore** — if your device supports it, install directly

## Project structure

```
Sources/
  App/            — SwiftUI app entry, root views, Info.plist
  Bluetooth/      — CoreBluetooth wrapper, GATT constants, DataX framing
  Crypto/         — AES-256-GCM, RSA-OAEP, PhaseB handshake, Keychain identity
  MediaTransfer/  — SoftAP Wi-Fi management, HTTPS media downloads
  Models/         — Observable glasses state, capture metadata, SwiftData models
  Storage/        — Local file management, Photos export
  UI/             — Dashboard, Gallery, Settings, ConnectionButton
```

## Protocol details

| Item | Value |
|------|-------|
| Service UUID | `0xFD5F` |
| DataX characteristic | `24154476-0E45-11AB-6441-E8BE42459478` |
| Battery service | `0x180F` / `0x2A19` |
| Auth: StartSession | `0x00` / `0x01` |
| Auth: Identity | `0x09` / `0x0A` |
| Auth: StartChallenge | `0x0D` / `0x0E` |
| Auth: FinishChallenge | `0x05` / `0x06` |
| Encrypted message | `0x02` |
| SoftAP IP | `192.168.1.1` |
| Asset URL | `https://192.168.1.1/stella-webserver/asset?id=<id>` |
| Photo type | `3073` (0x0C01) |
| Video type | `3074` (0x0C02) |

## License

MIT. See [LICENSE](LICENSE).
