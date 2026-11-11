# Zapmirror

*Your Android phone, on your Mac*

**See and control your Android phone in a window on your Mac, over USB.** Free and open source.

- The phone's screen, live, with its sound playing on your Mac.
- Click, drag, scroll and type with your Mac's mouse and keyboard.
- Copy and paste text between the phone and the Mac.
- No account, no ads, no telemetry. Zapmirror never touches the network.
- Nothing to install on the phone, and no root.

> Status: **early (1.0.0)**. Tested on a Pixel 9 Pro XL with Android 17. Please report phones that misbehave.

## What you need

- A Mac with macOS 14 or later.
- An Android phone and a USB cable that carries data. Sound needs Android 11 or later.
- Android's platform tools (adb) on the Mac, for now. With [Homebrew](https://brew.sh):

  ```bash
  brew install --cask android-platform-tools
  ```

  A later version will talk to the phone directly and drop this step.

## Using Zapmirror

Turn on USB debugging once:

1. On the phone, open **Settings → About phone** and tap **Build number** seven times.
2. Go to **Settings → System → Developer options** and switch on **USB debugging**.
3. Plug the phone into the Mac and unlock it.
4. When the phone asks **Allow USB debugging?**, tick **Always allow from this computer** and tap **Allow**.

Then open Zapmirror and press **Connect**. Zapmirror never connects on its own.

In the mirror window:

| To do this | Do this |
| --- | --- |
| Tap, drag, long-press | Click and drag with the mouse |
| Scroll | Trackpad or mouse wheel |
| Type | Just type |
| Back | Right-click, or ⌘[ |
| Home | Middle-click, or ⇧⌘H |
| Recent apps | ⇧⌘A |
| Volume | ⌘↑ and ⌘↓ |
| Mute the phone's sound on the Mac | ⇧⌘M |
| Power button | ⇧⌘P |
| Turn the phone's own screen off or on | ⇧⌘O |
| Rotate | ⌘R |
| Notifications, quick settings | ⇧⌘N, ⌥⇧⌘N |
| Copy from the phone to the Mac | Select on the phone, then ⌘C |
| Paste from the Mac to the phone | ⌘V |
| Disconnect | ⇧⌘D |

Good to know:

- While mirroring, the phone's sound plays on the Mac and its own speaker is quiet.
- The phone stays awake while mirroring. Mirroring ends when you lock the Mac, put it to sleep or switch user,
  so an unattended phone goes back to locking itself.
- Text copied on the phone reaches the Mac only when you press ⌘C in the mirror window.

## Privacy and security

- Zapmirror has no networking code. Nothing leaves your Mac.
- USB debugging lets this Mac control the phone. Once you tap "Always allow", any program running as you on
  this Mac can reach the phone through adb, with or without Zapmirror. To take that back, use
  **Developer options → Revoke USB debugging authorisations** on the phone, or switch USB debugging off.
- For each session Zapmirror puts a small component on the phone (`/data/local/tmp/zapmirror-phone.jar`). It
  runs only while you mirror, accepts connections only from adb, and deletes itself when you disconnect.

## Building

Needs the Xcode Command Line Tools and a JDK (11 or later).

```bash
Scripts/fetch-android-tools.sh
```

```bash
Scripts/build-app.sh
```

```bash
Scripts/test.sh
```

`fetch-android-tools.sh` downloads Android's API library and Google's d8 (about 82 MB, checksum-verified), which
the phone component is built with. `build-app.sh` makes `dist/Zapmirror.app`, ad-hoc signed unless
`ZAPMIRROR_SIGN_IDENTITY` names a Developer ID. The optional support link is `SUPPORT_URL` in `Scripts/config.sh`.

How it works: [`docs/MIRRORING-PLAN.md`](docs/MIRRORING-PLAN.md) and
[`docs/PHONE-PROTOCOL.md`](docs/PHONE-PROTOCOL.md).

- `Phone/src`: the phone component, in Java.
- `Sources/ZapmirrorADB`: talks to the adb server.
- `Sources/ZapmirrorPhone`: the Mac side of the phone protocol.
- `App/Zapmirror`: the SwiftUI app.

Log: `/usr/bin/log show --last 10m --predicate 'process == "Zapmirror" AND category == "mirror"'`

## Support

Zapmirror is free. If it helps you, you can [buy me a coffee](https://buymeacoffee.com/sr48).

## Licence

[MIT](LICENSE).
