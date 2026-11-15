# Zapmirror mirroring plan

Zapmirror has two halves, both ours:

- **The phone component** (`Phone/src`, Java, built by `Scripts/build-phone.sh` into a 17 KB dex jar). The Mac
  installs it for each session and starts it as the shell user. It mirrors the screen into Android's hardware H.264
  encoder, captures the sound, and injects the Mac's input.
- **The Mac app**, a SwiftUI client: hardware decoding (VideoToolbox) and Mac-style input.

They talk Zapmirror's own protocol, documented in docs/PHONE-PROTOCOL.md.

## How a session works

1. **Find the phone.** Talk to the Android Debug Bridge (adb) server over its host protocol on `localhost:5037`:
   `host:devices-l` lists phones with their state (`device`, `unauthorized`, `offline`).
2. **Install the component:** `sync:` service, `SEND /data/local/tmp/zapmirror-phone.jar`.
3. **Start it:** `shell:CLASSPATH=… app_process / app.zapmirror.phone.Main 1 <token> …`, then wait for
   `zapmirror: listening`. The shell stays open for the whole session.
4. **Connect** to `localabstract:zapmirror-<token>` straight through the adb transport (no `adb forward` needed):
   video, audio and control connections, each opened with a hello frame naming it.
5. **Video:** phone info, then a size and H.264 configuration on every rotation, then frames, into an
   `AVSampleBufferDisplayLayer`. **Audio:** raw PCM into `AVAudioEngine`.
6. **Control:** touches, scrolls, keys, text, clipboard, panels, screen power and rotation; the phone sends clipboard
   changes back. When the Mac disconnects, the component restores the screen and rotation and exits.

## Features

| Feature | Zapmirror | Stage |
|---|---|---|
| Mirror the screen, low latency, rotation | Mirror window, aspect-fit, follows rotation | A |
| Mouse as touch; scroll | Click and drag = touch; trackpad/wheel scroll | A |
| Keyboard: text and keys | Typing (text injection) plus Return, Delete, arrows, Tab, Escape… | A |
| Buttons: Back, Home, Recents, volume, power | Toolbar + Phone menu (⌘[, ⇧⌘H, ⇧⌘A, ⌘↑/↓, ⇧⌘P); right-click = Back, middle-click = Home | A |
| Turn device screen off while mirroring | Toolbar toggle (⌘O / ⇧⌘O) | A |
| Rotate device, notification/settings panels | Menu items (⌘R, ⌘N, ⇧⌘N) | A |
| Copy-paste both ways | Mac clipboard ⇄ phone clipboard (automatic) | A |
| Quality: max size, bit rate, fps, codec | Settings → Video (H.264 first; H.265 later) | A/B |
| Stay awake | Keeps the phone awake while plugged in | A |
| Audio forwarding (Android 11+) | Play phone audio on the Mac, mute toggle (⇧⌘M) | B (done) |
| Drag & drop APK / file | Install apps; send files to Downloads | B |
| Recording; screenshots | Record to MP4 in Movies/Zapmirror (AVAssetWriter, video not re-encoded, sound as AAC), ⇧⌘R. Screenshots still to do | B (recording done) |
| Pinch-to-zoom, two-finger tilt | Trackpad pinch → two virtual fingers | B |
| Virtual display, start app | Open an app in its own window on the Mac | B |
| Physical keyboard/mouse (HID), gamepad | Later, if wanted | C |
| Camera mirroring | Later, if wanted | C |
| Wireless (TCP/IP) | Connect over Wi-Fi after the first USB pairing | C |
| — | **Built-in USB connection**: our own adb protocol over USB, so buyers install nothing | C |
| — | Screen AI features (on-device) | D |

## Connection: now and later

Stage A uses the adb server already on the Mac (Android platform-tools; Zapmirror starts it if needed). That's
fine for development and for people who have adb. Before launch, stage C adds a built-in USB transport speaking
the adb protocol directly (CNXN/AUTH/OPEN/WRTE over libusb, with Zapmirror's own RSA key), so buyers need nothing
else. The adb-server path stays as the fallback when another adb server (Android Studio, say) already owns the
phone's debugging interface. Both implement the same `AdbDevice` interface: "open a service, get a stream".

## Setup the user has to do once

Developer options → USB debugging on, then "Allow USB debugging?" on the phone. Zapmirror shows these steps when
it sees the phone's USB connection but can't use debugging yet.
