# Zapmirror phone protocol, version 1

How the Mac app talks to Zapmirror's phone component (`Phone/`, built by `Scripts/build-phone.sh`). Both sides are
ours; this file is the contract between them. Change `Main.VERSION` (Java) and `PhoneServer.protocolVersion` (Swift)
together whenever anything here changes incompatibly.

## Starting

1. The Mac pushes `zapmirror-phone.jar` (a dex jar) to `/data/local/tmp/zapmirror-phone.jar` over adb's sync service.
2. It runs, through adb's `shell:` service:

   ```
   CLASSPATH=/data/local/tmp/zapmirror-phone.jar app_process / app.zapmirror.phone.Main 1 <token> [options]
   ```

   `1` is the protocol version (the component refuses any other) and `<token>` 32 random hex digits chosen by
   the Mac.
   Options: `--max-size N` (longest video side, pixels), `--bit-rate N` (bits/s), `--fps N`, `--no-audio`,
   `--no-stay-awake`.
3. The component runs as the shell user and listens on the abstract Unix socket `zapmirror-<token>`. When it is ready it
   prints `zapmirror: listening`. Everything it prints starts with `zapmirror: `.
4. The Mac opens up to three connections with adb's `localabstract:` service, in any order. The first frame on each
   is a hello naming the channel: `video`, `audio` or `control`. The component accepts connections only from the
   shell user or root (that is, from adb), one per channel, and stops listening once all have connected.
5. The session ends when the video or control connection closes. The component then restores what it changed (screen
   power, rotation lock), deletes its jar and exits; the Mac keeps the shell open until it does, for at most two seconds.

## Frames

Every message, in both directions, is one frame:

| bytes | field |
| --- | --- |
| 1 | type, an ASCII letter |
| 4 | payload length, big-endian, at most 32 MiB |
| n | payload |

Numbers inside payloads are big-endian; floats are IEEE 754 single precision. Text is UTF-8. A side that receives a
type it doesn't know skips the frame, so either side can add messages without breaking the other.

| type | direction | payload |
| --- | --- | --- |
| `h` | Mac → phone, first frame | channel name |

## Video channel (phone → Mac)

| type | payload |
| --- | --- |
| `I` | JSON: `{"name": "Pixel 9 Pro XL", "manufacturer": "Google", "android": "17"}`. Always first. |
| `D` | u32 width, u32 height (each 16…8192): a new video size. Sent before the first frame and after every rotation. |
| `C` | H.264 codec configuration (SPS and PPS, Annex B). Follows every `D`. |
| `F` | u64 presentation time (µs), u8 flags (bit 0: key frame), then one H.264 access unit (Annex B). |
| `E` | Text: why video stopped. The connection closes after it. |

## Audio channel (phone → Mac)

| type | payload |
| --- | --- |
| `I` | JSON: `{"encoding": "pcm16le", "rate": 48000, "channels": 2}`. |
| `E` | Text: why there is no sound (for example Android 10 or earlier). Video carries on. |
| `S` | Interleaved little-endian 16-bit samples. |

Capturing the sound moves it from the phone's speaker to the Mac for the length of the session.

## Control channel

Mac → phone. Positions are fractions of the screen (0…1 from the top-left), so they stay right across rotations and
scaling.

| type | payload | does |
| --- | --- | --- |
| `k` | u8 action (0 down, 1 up), i32 Android keycode, i32 meta state, i32 repeat count | key event |
| `t` | text | types the text; what the virtual keyboard can't type is pasted |
| `p` | u8 action (0 down, 1 move, 2 up), u8 finger (0 or 1), f32 x, f32 y, f32 pressure | touch |
| `w` | f32 x, f32 y, f32 horizontal, f32 vertical (wheel notches; positive is right and up) | scroll |
| `b` | — | Back, or wakes the phone if its screen is off |
| `n` | u8: 0 notifications, 1 quick settings, 2 close | status bar panels |
| `g` | u8: 0 copy, 1 cut | copies the phone's selection; the text comes back as `c` |
| `s` | u8 paste (0 or 1), text | sets the phone's clipboard, then pastes if asked |
| `d` | u8: 0 off, 1 on | the phone's own screen; mirroring continues |
| `r` | — | rotates between portrait and landscape |
| `v` | — | makes the next video frame a key frame (the Mac started recording) |

Phone → Mac:

| type | payload |
| --- | --- |
| `c` | Text: what the phone copied, sent only within two seconds of a `g`, and only up to 1 MiB. Other clipboard changes stay on the phone. |
