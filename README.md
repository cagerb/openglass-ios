# OpenGlass

An open-source iOS companion app for **Meta Ray-Ban Stories gen 1** smart glasses. Replaces the official Meta AI app with full local control over your glasses — no cloud, no Meta account required after initial setup.

## What it does

- **Official SDK connection** — uses the [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios) for BLE pairing and session management (no key extraction needed)
- **Live camera streaming** — real-time video feed from your glasses to your iPhone
- **Photo capture** — snap photos through the app while streaming
- **Audio streaming** — access to glasses microphone (foundation for Claude voice assistant)
- **Media transfer** — SoftAP Wi-Fi download of stored photos and videos from the glasses
- **Local storage** — saves captures with SwiftData, exports to the iOS Photos library
- **Gallery** — grid view of captures with live session photos and stored media
- **Dashboard** — connection status, live camera preview, battery, and storage info

## Requirements

- iOS 17.2+
- Xcode 26.4+ (Swift 6.3)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the `.xcodeproj`)
- Meta Ray-Ban Stories gen 1 or gen 2 glasses
- Meta AI app installed (for one-time Developer Mode setup and registration)

## First-time setup

1. Install the Meta AI app on your iPhone
2. Connect your glasses to the Meta AI app normally
3. Enable **Developer Mode**: Settings > App Info > tap version number 5 times > toggle Developer Mode on
4. Open OpenGlass and tap **Register with Glasses** — this opens the Meta AI app to authorize the connection
5. Once registered, tap **Connect to Glasses** to start a session

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

Install the unsigned `.ipa` on your iPhone with:

- **AltStore** — drag the `.ipa` into AltStore (7-day refresh with free Apple ID)
- **Sideloadly** — connect your iPhone and sideload
- **TrollStore** — if your device supports it, install directly

## Project structure

```
Sources/
  App/            — SwiftUI app entry, root views, Info.plist
  SDK/            — Meta Wearables DAT SDK wrapper (connection, camera, session)
  Bluetooth/      — CoreBluetooth wrapper, GATT constants, DataX framing (SoftAP commands)
  Crypto/         — AES-256-GCM, RSA-OAEP, PhaseB handshake (legacy, kept for reference)
  MediaTransfer/  — SoftAP Wi-Fi management, HTTPS media downloads
  Models/         — Observable glasses state, capture metadata, SwiftData models
  Storage/        — Local file management, Photos export
  UI/             — Dashboard, Gallery, Settings, ConnectionButton
```

## Architecture

OpenGlass uses a **hybrid approach**:

- **Meta DAT SDK** handles BLE connection, authentication, camera streaming, and audio — no manual key extraction or reverse-engineered handshake needed
- **Custom SoftAP code** handles downloading stored media (photos/videos already on the glasses) over the glasses' built-in Wi-Fi access point, since the SDK doesn't support media transfer yet

## Privacy

All data stays on your iPhone. The SDK communicates directly with the glasses over Bluetooth — no Meta cloud, no telemetry (SDK analytics and crash reporting are opted out in Info.plist). Your photos and videos are stored locally in the app's Documents directory.

## License

MIT. See [LICENSE](LICENSE).
