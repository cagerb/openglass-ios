# Custom Firmware on Ray-Ban Meta Gen 2 — Without an Android Phone

**Date:** 2026-11-18
**Status:** Research — not actionable yet, paths ranked by feasibility

---

## TL;DR

An Android phone is currently needed for the **known** firmware flash path, but there
are three realistic routes to eliminate it. The owner key we already extracted is the
single biggest enabler — it proves ownership over BLE/AirShield, which unlocks the
firmware delivery services. The question is whether we can replicate what the Meta AI
app does from Windows or iOS instead.

---

## 1. How Meta Pushes Firmware Today

Source: [visor.macedonga.com/protocol/firmware](https://visor.macedonga.com/protocol/firmware),
[p0pcycle.com writeup](https://p0pcycle.com/2026/11/06/hacking-the-meta-ray-ban-smartglasses/)

### Query
- Phone sends a GraphQL request to `ar-genai.graph.meta.com` with the AR OAuth token.
- Operation: `FetchConstellationUpdates` — includes serial, device type
  (`ota.greathammerhead.user`), current firmware version, full-image flag.
- Version `0` requests the full image. Reply has a signed download URL + SHA-256 checksum.
- Rollout is per-serial (staged). Delta images not observed.

### Delivery
- Phone downloads the ZIP (~156 MB full, payload.bin inside — standard Android OTA format).
- Phone opens svc29 (firmware service) on DataX and starts an update session (type 2000).
- Phone sends the firmware over **Airship file transfer (svc20)**, namespace `ota`,
  using the svc29 request UUID.
- Airship is just chunked data over AirShield with adler32 integrity — **no per-chunk
  signing or authentication beyond the AirShield link itself**.
- The glasses validate the OTA package internally (Android verified boot / dm-verity).

### Key Insight
The delivery channel (svc20 `ota` namespace) has **no transport-level signing**. The
security comes from:
1. The AirShield encrypted link (we have this)
2. Owner trust via svc36 (we're building this)
3. The glasses' internal OTA verification (Android verified boot)

Item 3 is the hard part — the glasses verify the OTA package is signed by Meta's
release keys before applying it.

---

## 2. What the Researcher Proved (p0pcycle, Nov 2026)

### What Worked
- Pulled full firmware from Meta's OTA CDN by hooking the Meta AI app with Frida
- Replaced Device Access Toolkit (DAT) APK with a self-signed one
- Got a user-level shell (uid 10097, TCP 31337 bind shell) — **not root**
- After Meta patched (fw 127), bypassed signature check by flipping one byte in
  `0.mctable` (MobileConfig file): `wss_appmanager.signature_verification_enabled`
  changed from `0x80` to `0x00`

### What Didn't Work
- No root access achieved
- No firmware modification demonstrated
- Was still looking for privilege escalation when access stopped working
- Bug reported to Meta via bug bounty, reportedly patched

### Critical Detail
**The entire chain required an Android phone** — the Meta AI app handles OTA fetch,
DAT installation, Wi-Fi Direct link, and MobileConfig delivery. The researcher did not
explore phone-free paths.

---

## 3. Paths to Custom Firmware Without Android

### Path A: Replicate the OTA Pipeline from Windows/iOS (Most Feasible)

**What we need:**
1. ✅ Owner key (extracted from G-Link Direct)
2. ✅ AirShield link (working from iOS via OpenGlass)
3. ✅ svc36 trust exchange (building now)
4. 🔲 Meta AR OAuth token (need Meta account auth — can be done from any platform)
5. 🔲 GraphQL query to `ar-genai.graph.meta.com` to get the OTA download URL
6. 🔲 svc29 firmware session (message types documented at visor.macedonga.com)
7. 🔲 svc20 Airship `ota` namespace sender (protocol fully documented)
8. 🔲 MobileConfig sender to disable signature verification (svc19 → svc20 `mobileconfig`)

**How it works:**
- OpenGlass connects via BLE, completes AirShield + owner trust
- Fetch the OTA URL from Meta's GraphQL endpoint (this is just HTTPS, works from anywhere)
- Download the ZIP on the PC/phone
- Send it via Airship `ota` namespace over the existing AirShield link
- The tricky part: the glasses will verify the OTA package with Android verified boot

**For stock firmware:** This just works — we're sending Meta's signed package. This
replaces the Meta AI app entirely for firmware updates.

**For custom firmware:** We'd need to either:
- Disable OTA verification via MobileConfig (if such a flag exists — unconfirmed)
- Modify the OTA package and re-sign with our own keys after replacing the
  verification keys on the device (requires root first)

**Effort:** Medium. The Airship sender protocol is fully documented. The GraphQL
endpoint needs reverse-engineering of the auth flow, but it's standard OAuth.

### Path B: DAT Shell → Root → Flash (Needs One-Time Android, Then Never Again)

**What it is:**
Use the p0pcycle researcher's approach to get a shell on the glasses, escalate to
root, then modify the boot chain to accept custom-signed firmware permanently.

**Steps:**
1. Borrow an Android phone ONE TIME
2. Install Meta AI app, pair glasses
3. Reproduce the DAT sideload (may need firmware ≤126, or MobileConfig bypass)
4. Get shell access, find privilege escalation to root
5. Modify verified boot keys / dm-verity to accept our signatures
6. Flash custom firmware
7. After this, the glasses accept our keys — never need Android again

**Status:** Theoretical. The researcher got user shell but NOT root. Privilege
escalation on Android 14 with release-keys is non-trivial. The MobileConfig bypass
may have been patched. Would need to find a local privilege escalation (LPE) exploit.

**Effort:** High. Requires Android (once), LPE research, boot chain modification.

### Path C: USB-C / Hardware Access (Nuclear Option)

**What we know:**
- The glasses have USB-C (charging port in the case)
- Qualcomm SoCs support EDL (Emergency Download Mode) via USB
- EDL requires either: `adb reboot edl`, `fastboot oem edl`, or shorting test points
- In EDL, tools like QFIL can flash firmware images
- BUT: Qualcomm's Sahara/Firehose protocol requires signed programmers (MBN files)
  specific to the device — these are under NDA and device-specific

**What we don't know:**
- Whether the USB-C port exposes data pins (it may be power-only in the case)
- Whether the AR1 Gen 1 chip supports standard EDL (it's a custom Qualcomm part)
- Whether there are accessible test points on the PCB
- Whether EDL requires a signed programmer (almost certainly yes for release devices)

**Research needed:**
- Teardown to check USB-C data lines and test points
- Try connecting via USB and check for `05c6:9008` (Qualcomm EDL) VID/PID
- Check if holding power + USB triggers any boot mode

**Effort:** Very high. Physical teardown risk, likely needs signed Qualcomm programmer
files that aren't publicly available.

---

## 4. What Custom Firmware Would Change

If we get flash access, a custom build would:

| Change | Benefit |
|--------|---------|
| Remove telemetry services | No data to Meta servers |
| Remove PKI verification for apps | Sideload anything without MobileConfig hacks |
| Remove forced OTA updates | Stay on our version, prevent Meta from patching |
| Unlock camera LED override | Record without LED (privacy implications — your call) |
| Persistent root (su binary) | Full system access for future modifications |
| Custom system apps | Replace Meta AI with OpenGlass as the system companion |
| Unlock hardware limits | Higher resolution, longer recording, different codecs |
| Remove Meta account requirement | Glasses work without any Meta login |

---

## 5. Recommended Plan

### Phase 1: Stock OTA from OpenGlass (No Android needed)
Build the svc29 + svc20 Airship sender into OpenGlass. This lets us push Meta's own
signed firmware updates to the glasses from iOS — replacing the Meta AI app for updates
entirely. This is useful RIGHT NOW even without custom firmware.

**Prerequisites:** Owner trust (building now), Meta OAuth token acquisition, Airship
sender implementation.

### Phase 2: MobileConfig Control
Implement svc19 MobileConfig delivery in OpenGlass. This gives us control over all of
Meta's feature flags, including:
- `wss_appmanager.signature_verification_enabled` (app signing bypass)
- `wearables_dat.enable_dwa` (DAT enable/disable)
- Other gates we haven't mapped yet

This may be enough to sideload unsigned apps directly from iOS.

### Phase 3: Shell Access from iOS
If MobileConfig lets us disable app signing, we can sideload a shell app onto the
glasses directly from OpenGlass — no Android needed. The shell app listens on TCP
31337 over Wi-Fi Direct (which OpenGlass can establish).

### Phase 4: Root + Custom Firmware
From the shell, research privilege escalation. If we find a local root exploit:
- Modify dm-verity / verified boot to accept our signing keys
- Build and sign our own firmware images
- Flash via the OTA path we built in Phase 1

### Alternative: One-Time Android Shortcut
If Phase 3 stalls (no MobileConfig bypass for app signing), borrowing an Android phone
for one session to get the initial shell access is the fastest path. After rooting and
modifying the boot chain, the phone is never needed again.

---

## 6. Sources

- [Visor Protocol — Firmware](https://visor.macedonga.com/protocol/firmware)
- [Visor Protocol — Airship File Transfer](https://visor.macedonga.com/protocol/airship-file-transfer)
- [Visor Protocol — Device Access Toolkit](https://visor.macedonga.com/protocol/device-access-toolkit)
- [Visor Protocol — MobileConfig](https://visor.macedonga.com/protocol/mobileconfig)
- [p0pcycle — Hacking the Meta Ray-Ban Smartglasses](https://p0pcycle.com/2026/11/06/hacking-the-meta-ray-ban-smartglasses/)
- [Cybernews — Ray-Ban Meta hack](https://cybernews.com/security/meta-ray-ban-smart-glasses-hack-code-execution/)
- [IT-Connect — Shell Access and Patch Bypass](https://www.it-connect.tech/ray-ban-meta-smart-glasses-hacked-researcher-gets-a-shell-then-bypasses-metas-patch/)
- [DTU NetSec — Reverse Engineering Ray-Ban Metas](https://netsec-dtu.pages.dev/project/report/ReverseEngineeringRayBanMetas.pdf)
- [XDA Forums — Meta RayBan Custom Firmware](https://xdaforums.com/t/meta-rayban-custom-firmware.4749426/)
- [GitHub — macedonga/visor](https://github.com/macedonga/visor)
- [Qualcomm EDL mode — Wikipedia](https://en.wikipedia.org/wiki/Qualcomm_EDL_mode)
- [Visor Protocol Index](https://visor.macedonga.com/protocol)
