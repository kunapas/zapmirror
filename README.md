# Zapmirror (private)

Show and control your Android phone on your Mac, over USB: screen, sound, touch, keyboard and clipboard. Free; the
app can show a "Buy Me a Coffee" link for anyone who wants to support the work.

## Layout

- `Sources/ZapmirrorADB`: talks to the adb server (list phones, push files, run commands, open phone sockets).
- `Sources/ZapmirrorPhone`: the Mac side of the phone protocol (docs/PHONE-PROTOCOL.md).
- `Phone/src`: the phone component, in Java. `Scripts/fetch-android-tools.sh` downloads what building it needs
  (Android's API library and d8, about 82 MB, checksum-verified); `Scripts/build-phone.sh` builds it, and
  `build-app.sh` runs that for you. Needs a JDK.
- `App/Zapmirror`: the SwiftUI app. `App/Support`: Info.plist template and entitlements.
- `Scripts`: build, tests, icon. `docs/MIRRORING-PLAN.md`: how a session works and what's planned.

## Building and testing

```bash
Scripts/test.sh
```

```bash
Scripts/build-app.sh
```

`build-app.sh` makes `dist/Zapmirror.app`, ad-hoc signed unless `ZAPMIRROR_SIGN_IDENTITY` names a Developer ID.
The support link is `SUPPORT_URL` in `Scripts/config.sh` (or `ZAPMIRROR_SUPPORT_URL=https://… Scripts/build-app.sh`);
left empty, the link doesn't appear.

Log: `/usr/bin/log show --last 10m --predicate 'process == "Zapmirror" AND category == "mirror"'` (the phone
component's lines appear as `phone: zapmirror: …`).
