# OpenGlass — Full Project Handoff

> Last updated: 2026-11-18
> Repo: `cagerb/openglass-ios` (GitHub)
> Source: `C:\Users\cager\Documents\OpenGlass`

---

## 1. What This Is

OpenGlass is a **Swift/iOS companion app for the Ray-Ban Meta gen 2+ smart glasses**. The goal is to **fully replace Meta's app and remove all Meta dependencies** — Cager wants these glasses to be entirely his, with no ties to Meta at all.

The app connects over BLE, opens an L2CAP channel, establishes the AirShield encrypted transport, and communicates via DataX messages. It's unsigned and sideloaded via AltStore.

### The Glasses

| Field | Value |
|---|---|
| Model | Ray-Ban Meta (gen 2+), codename `hammerhead` |
| Advertised name | `RB Meta 0G53` |
| OS | Android 14 `supernova`, Qualcomm AR1 Gen 1 SoC |
| Serial | `2Q9GS00H9T0G53` |
| Firmware | `68449720064700100` |

**CRITICAL**: These are gen 2 glasses, NOT gen 1 (Ray-Ban Stories). The protocols are completely different. Gen 1 uses GATT DataX + RSA-OAEP. Gen 2 uses L2CAP + AirShield (P-256 ECDH, AES-256-CBC + HMAC-SHA256). Most of the code in `Sources/Crypto/` is dead gen 1 code.

---

## 2. Build System

| Item | Detail |
|---|---|
| Language | Swift 6.3, strict concurrency (`complete`) |
| Project generator | XcodeGen (`project.yml`) |
| Deployment target | iOS 17.2 |
| Bundle ID | `com.openglass.app` |
| Version | 0.3.0 (build 3) |
| Code signing | Manual, unsigned (CODE_SIGN_IDENTITY = "") |
| CI | GitHub Actions on `macos-15`, workflow at `.github/workflows/build.yml` |
| Sideloading | AltStore on iPhone |

### Build Pipeline

1. Push to `master` triggers CI
2. CI: `xcodegen generate` → `xcodebuild archive` (unsigned) → package `.ipa` → upload as artifact
3. Download artifact via `gh run download` → copy `OpenGlass.ipa` to `C:\Users\cager\Documents\OpenGlass\OpenGlass.ipa`
4. Sideload via AltStore

### Local Build Commands (PowerShell)

Check CI status:
```powershell
gh run list --repo cagerb/openglass-ios --limit 3
```

Download latest IPA after CI passes:
```powershell
gh run download --repo cagerb/openglass-ios --name OpenGlass-ipa --dir "$env:TEMP\openglass-ipa"
Copy-Item "$env:TEMP\openglass-ipa\OpenGlass.ipa" "C:\Users\cager\Documents\OpenGlass\OpenGlass.ipa" -Force
```

**Important**: Always copy the IPA to the OpenGlass folder, never use SendUserFile. Cager wants the file in the folder.

---

## 3. Source Map

### Directory Structure

```
Sources/
├── App/
│   ├── OpenGlassApp.swift          # @main entry point
│   ├── GlassesController.swift     # @Observable @MainActor app state machine
│   ├── ContentView.swift           # Tab container
│   └── Info.plist / OpenGlass.entitlements
├── Bluetooth/
│   ├── BluetoothManager.swift      # BLE scan/connect/L2CAP/AirShield orchestration
│   ├── AirShieldLink.swift         # Encrypted transport (ECDH, AES-CBC, HMAC, DataX)
│   ├── L2CAPPipe.swift             # L2CAP stream wrapper (NSStream pair on main run loop)
│   ├── GATTConstants.swift         # GATT UUIDs, PSM, auth constants
│   ├── DataXLink.swift             # Gen 1 GATT DataX framing (DEAD CODE for gen 2)
│   └── OwnershipForger.swift       # Receipt forgery state machine (svc36 change-owner)
├── Crypto/
│   ├── AuthHandshake.swift         # PhaseB RSA-OAEP handshake (DEAD CODE — gen 1 only)
│   ├── RSAAuth.swift               # RSA operations (DEAD CODE — gen 1 only)
│   ├── SessionCrypto.swift         # AES-256-GCM sessions (DEAD CODE — gen 1 only)
│   └── IdentityStore.swift         # Keychain storage for RSA key + bootstrap ticket (gen 1)
├── Models/
│   ├── GlassesState.swift          # Storage/battery state model
│   └── Capture.swift               # Photo/video capture model
├── MediaTransfer/
│   ├── SoftAPManager.swift         # Wi-Fi Direct media download
│   └── MediaDownloader.swift       # HTTP download from glasses' webserver
├── Storage/
│   └── LocalStore.swift            # Local persistence
├── StressTester/
│   ├── ProtocolStressTester.swift   # Main test driver
│   ├── StressStrategy.swift         # 17 test strategies
│   ├── AnomalyDetector.swift        # Pattern recognition for anomalies
│   └── StressTesterView.swift       # SwiftUI UI for stress testing
└── UI/
    ├── DashboardView.swift          # Main view: connection, device info, forgery card, debug log
    ├── ConnectionButton.swift       # Nav bar connect/disconnect button
    ├── SettingsView.swift           # Settings tab
    └── GalleryView.swift            # Photo/video gallery tab
```

### Key Files In Detail

#### `BluetoothManager.swift` (~500 lines)
The core BLE orchestrator. `@Observable` class running on a custom `bleQueue` (DispatchQueue). Handles:
- CBCentralManager scanning (unfiltered, name-matched to "RB*")
- Peripheral connection with generation tracking for stale callback protection
- Service/characteristic discovery with retry logic for the "FD5F reports 0 characteristics" bug
- L2CAP channel opening on PSM from the `05ACBE9F` characteristic
- AirShield link lifecycle (start, pipe callbacks, teardown)
- Ownership forgery orchestration

**Threading model**: All BLE and AirShield work runs on `bleQueue`. UI state is `@Observable` tracked properties. `@ObservationIgnored` is used for internal BLE state that shouldn't trigger SwiftUI re-renders.

**SwiftUI observation gotcha** (fixed 2026-11-18): Computed properties reading from `@ObservationIgnored` storage don't trigger view updates. The `isAirShieldSecure` property was changed from a computed `airShield?.phase == .secure` to a tracked stored `airShieldSecure` bool, set explicitly in `onSecure` and reset in both teardown paths (`tearDownL2CAP` and `pipe.onClosed`). The forger state (`forgerPhase`, `forgerFailure`) follows the same pattern — mirrored from the `OwnershipForger` instance into tracked properties on BluetoothManager.

#### `AirShieldLink.swift` (~788 lines)
The encrypted transport protocol. NOT thread-safe — must be called from `bleQueue`. Contains:

- **`ProtoWire`** (lines 34-106): Minimal protobuf encoder/decoder (varint, length-delimited fields). Used throughout for svc36 messages and receipt encoding.
- **`DataXHeader`** (lines 110-194): DataX message framing — 4-byte fixed header + optional 4-byte tags (service, type, error, closed). `build()` constructs headers, `parse()` reads them.
- **`AirShieldCrypto`** (lines 204-292): Key derivation (HKDF-SHA256), AES-256-CBC, HMAC-SHA256, modified PKCS#7 padding (pad byte = length + 0xC0).
- **`AirShieldFrameCipher`** (lines 294-351): Per-direction cipher with chaining IV and incrementing sequence number.
- **`AirShieldLink`** (lines 359-788): The main link class:
  - `start()` — Sends RequestEncryption + EnableEncryption (both carry our P-256 pubkey)
  - `feed()` — Accepts raw bytes from the pipe, cuts into SDUs, routes to handshake or secure handler
  - `finishHandshake()` — ECDH shared secret → derive TX/RX keys → install ciphers → process early frames → fire `onSecure`
  - `handleSecure()` — Decrypt frame → reassemble DataX stream (with carry buffer for messages split across frames) → dispatch via `onMessage`
  - `sendMessage()` — Encrypt DataX message into frames → send via pipe
  - `openChannel()` — Allocates channel IDs with originator bit 0x8000
  - `requestIdentity()` — Sends svc36 type 0x3000 (IDENTITY_REQUEST)

**Service tag convention**: The first message on a channel carries `serviceID`; subsequent messages on the same channel pass `serviceID: nil` (wire value 0).

#### `OwnershipForger.swift` (~239 lines)
State machine for the 4-step svc36 change-owner flow with **forged** Meta ownership receipts. The critical open question: **do the glasses verify Meta's receipt signatures?**

Flow:
1. `start()` → open channel → send IDENTITY_REQUEST (0x3000)
2. Handle IDENTITY_RESPONSE (0x3001) → extract deviceCert, serial, secondaryCert → send SKIP_CHALLENGE (0x2000)
3. Handle SKIP_CHALLENGE_ACK (0x2001) → extract nonce → forge pending receipt → send START_CHANGE_OWNER_REQ (0x2002) **← THE CRITICAL TEST**
4. If glasses return START_CHANGE_OWNER_RESP (0x2003) → they accepted our forged receipt → forge final receipt → send FINISH_CHANGE_OWNER_REQ (0x2004)
5. If FINISH_CHANGE_OWNER_RESP (0x2005) → **OWNERSHIP CLAIMED**

Receipt wire format (confirmed from visor `Provision.kt`):
```
protobuf { field 1: signature_bytes, field 2: json_body_bytes }
```
Swift: `ProtoWire.field(1, bytes: signature) + ProtoWire.field(2, bytes: jsonBody)`

The forger generates a P-256 key, self-signs the receipt body with it. If the glasses check the signature against Meta's public key, we get error 0x1040 (INVALID_RECEIPT) or 0x1044 (INVALID_SIGNATURE). If they DON'T check, we become the owner.

**Error codes the forger watches for:**
| Code | Name | Meaning |
|---|---|---|
| 0x1000 | SUCCESS | (not an error) |
| 0x1010 | KEY_NOT_FOUND | Unknown |
| 0x1040 | INVALID_RECEIPT | Glasses verify receipt signatures — forgery is dead |
| 0x1042 | INVALID_USER_ID | Glasses already owned by another Meta account |
| 0x1043 | INVALID_APP_IDENTITY | App identity rejected |
| 0x1044 | INVALID_SIGNATURE | Glasses verify the signature specifically |

#### `L2CAPPipe.swift` (~122 lines)
Wraps CoreBluetooth's L2CAP channel (NSStream pair) into a byte pipe. Runs on the main run loop. Callbacks (`onBytes`, `onEvent`, `onClosed`) are `@Sendable` closures called on the main thread; BluetoothManager bounces them to `bleQueue`.

#### `GlassesController.swift` (~193 lines)
`@Observable @MainActor` controller. Holds `let bluetooth = BluetoothManager()`. Maps BluetoothManager's connection states to its own `State` enum via a 250ms polling timer (`observeBluetooth()`). Views access bluetooth directly as `controller.bluetooth` for things like `isAirShieldSecure`, `forgerPhase`, `debugLog`.

#### `DashboardView.swift` (~480 lines)
Main SwiftUI view. Cards:
- **Connection card** — scan/stop/authenticate buttons, error display
- **Identity warning** — shown when no RSA identity exists
- **Discovered devices** — list of nearby glasses
- **Device info** — model, firmware, serial
- **Ownership Forgery** — purple card, gated on `controller.bluetooth.isAirShieldSecure`. Shows idle/in-progress/succeeded/failed states
- **Battery** — percentage with color coding
- **Storage** — progress bar
- **Debug log** — expandable, scrollable, monospaced, with copy button

---

## 4. Protocol Stack (Gen 2)

```
┌──────────────────────────────────┐
│          DataX Messages          │  Service IDs, message types, protobuf payloads
├──────────────────────────────────┤
│      AirShield Encryption        │  AES-256-CBC + HMAC-SHA256, chaining IV, seq counter
├──────────────────────────────────┤
│        AirShield Frames          │  0x40 | stream, 8-byte tag, block count, ciphertext
├──────────────────────────────────┤
│        L2CAP LE Channel          │  PSM 128 (0x80), read from GATT char 05ACBE9F
├──────────────────────────────────┤
│           BLE GATT               │  Service FD5F, encrypted char triggers iOS pairing
└──────────────────────────────────┘
```

### Connection Sequence

1. **Scan** — unfiltered BLE scan, name-match "RB*"; also `retrieveConnectedPeripherals` and `retrievePeripherals(withIdentifiers:)` for already-paired glasses
2. **Connect** — `centralManager.connect(peripheral)`
3. **Discover services** — `discoverServices(nil)` (all services, unfiltered)
4. **Read PSM** — Discover characteristics of FD5F, read `05ACBE9F` value → triggers iOS BLE pairing dialog → returns PSM bytes
5. **Open L2CAP** — `peripheral.openL2CAPChannel(128)` → `L2CAPPipe` wraps the NSStream pair
6. **AirShield handshake** — Exchange RequestEncryption + EnableEncryption in both directions → ECDH → derive keys → install ciphers
7. **Identity probe** — Send svc36 IDENTITY_REQUEST → get serial + device cert (proves encryption works)

### DataX Message Format

```
Byte 0-1: [flags|length_hi] [length_lo]  — 14-bit payload length
Byte 2-3: [channel_hi] [channel_lo]      — channel ID
If flags & 0x80: 4-byte tag blocks follow:
  [continuation|tag_id] [0x00] [value_hi] [value_lo]
  Tag 1 = serviceID, Tag 2 = messageType, Tag 3 = errorID, Tag 4 = messageType(closed)
Then: protobuf payload
```

### Key Services

| Service | Purpose | Needs Owner Key? |
|---|---|---|
| svc5 | Link setup (RequestEncryption / EnableEncryption) | No |
| svc36 | Identity, trust exchange, change-owner | Partially (identity probe works without) |
| svc4 | Device info | No |
| svc30 | Battery/status | No |
| svc79 | Debug/diagnostics | No |
| svc20 | Notifications | No |
| svc2000 | Unknown | No |

---

## 5. Ownership Problem

The glasses' real services (camera, media, settings, firmware) are locked behind **owner key** registration. Meta's flow:

1. App calls `graph.facebook-hardware.com/pair_request` with device cert, serial, nonce, app pubkey → gets back `pending_ownership_receipt` + `receipt_signature`
2. App sends the receipt (protobuf `{1: signature, 2: json_body}`) to glasses via svc36 START_CHANGE_OWNER_REQ (0x2002)
3. Glasses may require a physical button press (90s timeout)
4. Glasses return their own device receipt via START_CHANGE_OWNER_RESP (0x2003)
5. App calls `graph.facebook-hardware.com/pair` with device receipt → gets `final_ownership_receipt`
6. App sends final receipt via FINISH_CHANGE_OWNER_REQ (0x2004)
7. Glasses acknowledge with FINISH_CHANGE_OWNER_RESP (0x2005) → owner key installed

### Attack Vectors (Ranked)

1. **DAT APK swap** — PROVEN by Paula/@pamoutaf (p0pcycle.com). Needs ~$50 Android phone + Frida. Gets non-root app-context shell. Could extract owner key from Meta AI app. Cager doesn't have an Android phone.

2. **Receipt forgery** (CURRENT ATTEMPT) — Self-sign the receipt with our own P-256 key instead of Meta's. If glasses don't verify the signature → instant ownership without Meta. Built and in the app as the purple "Ownership Forgery" card. **Status: untested** — the UI bug preventing the button from appearing was just fixed.

3. **Pre-trust service fuzzing** — Probe svc36/svc4/svc30/svc79 for unexpected behavior. The stress tester has 17 strategies but encrypted sends were broken (same `isAirShieldSecure` bug, now fixed).

4. **MobileConfig tampering** — Glasses check format but NOT integrity of `.mctable` config files. Proven concept (Paula's 0.mctable bypass) but needs owner scope first.

5. **COMMAND frame collision** — DataX and COMMAND frames share bit patterns in a way that causes stream desync. Documented but not exploitable for code execution.

6. **Service 29 resource pack signing** — Weak signing on resource packs. Needs more research.

---

## 6. Stress Tester

Located in `Sources/StressTester/`. 17 strategies including:
- Raw L2CAP frame fuzzing (various lengths, malformed headers)
- AirShield frame injection (bad tags, wrong seq, corrupted ciphertext)
- DataX message fuzzing (oversized payloads, invalid service IDs, closed-channel replay)
- 4 targeted probes for oversized frame crash zone

**Key finding**: 8-packet watchdog confirmed — glasses disconnect after ~8 unrecognized raw frames. This is intentional defense, not exploitable.

**Status**: Encrypted sends were broken due to the same `isAirShieldSecure` bug. Now fixed. The encrypted attack surface has **NEVER been tested**.

---

## 7. What Works

- BLE scan, connect, service/char discovery
- BLE pairing (triggered by reading encrypted char `05ACBE9F`)
- L2CAP channel open on PSM 128
- AirShield encrypted handshake complete (multikey=true)
- Identity probe: serial "2Q9GS00H9T0G53", 1563-byte DER device certificate
- DataX messages flowing both directions over encrypted channel
- Full debug log UI with copy button
- Stress tester (raw L2CAP only — encrypted strategies now fixed but untested)
- Ownership forgery UI (just fixed 2026-11-18, untested on glasses)

## 8. What Doesn't Work / Is Blocked

- **Owner key** — Without it, glasses keep real services closed. The only Meta-free path that doesn't need an Android phone is receipt forgery (now built, untested).
- **Gen 1 auth code** — Dead code in `Sources/Crypto/`. The PhaseB RSA-OAEP handshake, bootstrap tickets, and GATT DataX are all gen 1 only. Kept but unused.
- **Media transfer** — SoftAP/Wi-Fi Direct download code exists but can't work without owner scope.
- **Camera/mic control** — Needs owner key.

---

## 9. Git History (Key Commits)

```
627e5d6 fix: reset airShieldSecure + forger state on disconnect
4168b85 Add ownership receipt forgery for svc36 change-owner flow
7774fdb Add targeted strategies for oversized frame crash zone
42b9e22 Fix strict-concurrency error in AnomalyDetector.exportJSON
0cf503b Add protocol stress tester for BLE parser bug hunting
8df9e4f Ray-Ban Meta link: L2CAP channel + AirShield handshake
0195b01 Fix FD5F "0 characteristics": unfiltered discovery, retries
7c7294f Add visible debug log + discover all BLE services
2e1f4ba Scan all BLE devices to find factory-reset paired glasses
```

---

## 10. External References

| Source | What It Has |
|---|---|
| [macedonga/visor](https://github.com/macedonga/visor) | Full Android replacement app, AGPL-3.0. `Provision.kt` has the receipt wire format. Protocol notes at visor.macedonga.com/protocol |
| [zhuowei/Starcruiser](https://github.com/zhuowei/Starcruiser) | AirShield handshake, protobuf schema, key test vectors |
| Paula/@pamoutaf, p0pcycle.com | Code execution research, DAT APK swap, `.mctable` bypass |
| DTU NetSec report (netsec-dtu.pages.dev) | BLE MITM/sniffing research (no code execution achieved) |
| [Meta DAT iOS SDK](https://github.com/facebook/meta-wearables-dat-ios) | Official SDK, used briefly then removed (commit 66001e2 → revert 7ef07f3) |

---

## 11. Environment Notes

- **No Android phone available** — rules out DAT APK swap and Frida extraction for now
- **GitHub signed in as `cagerb`**
- **Python path**: `C:\Users\cager\AppData\Local\Programs\Python\Python312\python.exe` (do NOT use `-I` flag)
- **`gh api` commands must run in PowerShell** — Git Bash rewrites API paths
- **Fable only organizes and checks work; every subagent on Sonnet** (Cager hit the Fable limit twice)
- **One lean workflow at a time** — don't spin up heavy parallel work

---

## 12. Immediate Next Steps

1. **Test the receipt forgery** — Sideload the latest IPA (627e5d6), connect to glasses, verify the purple forgery card appears, tap it, read the debug log. This is THE critical test.

2. **If forgery fails (0x1040/0x1044)** — Glasses verify signatures. Options:
   - Buy a cheap Android phone (~$50) for the DAT APK swap / Frida extraction path
   - Pre-trust service fuzzing (now that encrypted sends work)
   - Deeper firmware research

3. **If forgery succeeds** — We own the glasses without Meta. Next:
   - Persist the owner key (save P-256 private key to Keychain)
   - Implement the full trust exchange (svc36 owner auth flow)
   - Unlock real services: camera, media, settings, firmware
   - Build media download over SoftAP
   - Remove all dead gen 1 code

4. **Encrypted stress testing** — Now that `isAirShieldSecure` works correctly, the encrypted strategies in the stress tester should actually fire. Run them to map the encrypted attack surface.

---

## 13. Vault Notes

The project has a vault presence at `Projects/OpenGlass/` in the FullPort Media Business Brain vault, with:
- Protocol analysis: `Projects/OpenGlass/Protocol Analysis 2026-11-18.md`
- Memory: `~/.claude/projects/.../memory/openglass-project.md`

---

## 14. Known Bugs / Tech Debt

1. **Dead gen 1 code** — `AuthHandshake.swift`, `RSAAuth.swift`, `SessionCrypto.swift`, `IdentityStore.swift`, `DataXLink.swift` are all unused for gen 2 glasses. Safe to delete once gen 2 path is stable.

2. **GlassesController polling** — `observeBluetooth()` polls BluetoothManager at 250ms via `Task.detached`. Works but wastes cycles. Could be replaced with Combine/AsyncSequence observation.

3. **L2CAPPipe main thread** — The NSStream pair runs on the main run loop, then callbacks bounce to `bleQueue`. Not ideal but CoreBluetooth requires a run loop.

4. **No owner key persistence** — `OwnershipForger` generates a new P-256 key every time. If forgery succeeds, the key needs to be saved to Keychain and reused.

5. **Connection recovery** — The "FD5F reports 0 characteristics" bug has a workaround (force disconnect + reconnect, once per connection), but the root cause is unknown. Probably a CoreBluetooth caching issue.
