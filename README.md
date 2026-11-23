<p align="center">
  <img src="iPadOSClient/WiredDisplayClient/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="128" alt="WiredDisplay icon">
</p>

<h1 align="center">WiredDisplay</h1>

<p align="center">
  Turn an iPad into a wired USB‑C display for your Mac, with sound, touch, keyboard and trackpad.<br>
  Adapts to any iPad on iPadOS 17 or later, and can even be the only screen of a headless Mac.
</p>

---

WiredDisplay is a macOS menu-bar app plus an iPadOS app. The Mac creates a
real virtual display, streams it to the iPad over the USB‑C cable, and takes
input back from the iPad. It works like Sidecar, but it runs only over the
cable, has its own pairing, and can be the main display of a Mac with no
monitor attached.

## Screenshots

**Mac:** the menu bar panel (Display, Input and General tabs).

<p align="center">
  <img src="docs/images/host-display.png" width="260" alt="Menu bar panel, Display tab: display size, encoding, iPad brightness and quality preset">
  <img src="docs/images/host-input.png" width="260" alt="Menu bar panel, Input tab: allow input from the iPad and keyboard shortcuts">
  <img src="docs/images/host-general.png" width="260" alt="Menu bar panel, General tab: permissions, keep the display on, keep the Mac awake, open at login">
</p>

**iPad:** the app while it waits for the Mac. Once connected, the whole
screen is the Mac display.

<p align="center">
  <img src="docs/images/ipad-waiting.png" width="640" alt="iPad app waiting for the Mac, with the three setup steps">
</p>

## Features

- **Wired only.** Video, audio and input travel through `usbmuxd` over the
  USB‑C cable. The app never falls back to Wi‑Fi, and the Mac opens no
  network port.
- **A real display.** A virtual display at the iPad's native resolution with
  HiDPI "looks like" sizes: **Default**, **More Space** and **Most Space**,
  chosen from the menu bar panel and remembered for each iPad. For the larger
  sizes the Mac renders at the full HiDPI size and scales it down to the panel
  with its own area filter, which keeps text closer to native Retina. It can
  be the main display of a headless Mac.
- **Picture quality presets.** HEVC with low-latency and full-detail lanes:
  - **Balanced**
  - **Pro:** 4:2:0, 10-bit
  - **Ultra:** 4:4:4, 10-bit
  - **High Color:** 4:4:4, 8-bit

  You can switch presets live from the menu bar. If an iPad can't decode a
  format, or can't decode it fast enough, the Mac steps down for that iPad
  automatically.
- **Follows the Mac's sleep and lock.**
  - Display sleep keeps the session: the iPad goes black and the picture
    comes back when the displays wake.
  - System sleep closes the session cleanly, and it reconnects after wake.
  - While the Mac is locked or in a screensaver, the iPad shows the lock
    screen, never the desktop. A tap or key on the iPad wakes the displays,
    but nothing is clicked or typed into the lock screen.
  - **Keep the display on** and **Keep the Mac awake** choose whether the
    displays, or the Mac itself, may sleep on their own while an iPad is
    connected.
- **Audio both ways.** Mac sound plays on the iPad speakers, and the iPad
  microphone can be used on the Mac. Both are optional and use an included
  audio driver.
- **Sidecar-style touch.**
  - Tap: click.
  - Drag: scroll, with momentum.
  - Hold, then drag: select or move.
  - Two-finger tap: right click.
  - Pinch: zoom.
  - Two-finger rotate: rotate.
  - Three-finger pinch, spread and swipe: copy, paste, undo and redo.
- **Magic Keyboard and trackpad.**
  - Full keyboard with key repeat.
  - Two-finger scrolling with trackpad phases and momentum.
  - Real macOS **pinch-to-zoom** and **rotate** gestures.
  - Secondary click.
- **Mac shortcuts iPadOS would keep.** These are sent to the Mac with Command:

  | On the iPad keyboard | The Mac receives |
  |---|---|
  | `⌃ Tab`, `⌃ ⇧ Tab` | `⌘ Tab`, `⌘ ⇧ Tab`. Hold `⌃` to keep cycling. |
  | `` ⌃ ` `` | `` ⌘ ` `` |
  | `⌃ Space` | `⌘ Space` (Spotlight) |
  | `⌃ ⇧ 3 / 4 / 5` | `⌘ ⇧ 3 / 4 / 5` (screenshots) |

  `⌃ ↑` and `⌃ ← / →` reach Mission Control and Spaces as they are.
- **Secure by default.**
  - Every session uses an Ed25519 / X25519 handshake and AES‑256‑GCM
    encryption.
  - You pair once with a 6-digit code shown on both screens.
  - Input from the iPad is off until you allow it in the menu.
- **Adapts to each iPad.** The iPad reports its panel size, pixel density,
  refresh rate and hardware HEVC support, and the Mac builds the display to
  match. The iPad's Controls panel shows the same details under **This iPad**,
  including the model identifier.
- **Automatic headphone switching.** When AirPods, Bluetooth headphones or
  USB-C earphones connect, sound and the microphone move to them. When they
  disconnect, everything goes back to the iPad. An "output only" option
  keeps the iPad microphone, so AirPods keep full sound quality.
- **Real iPad brightness.** The Mac's brightness keys and a slider in the menu
  bar panel set the iPad's actual backlight instead of dimming the picture.
  This works with Apple keyboards and third-party keyboards.
- **Menu bar panel.** A Liquid Glass panel with the following tabs:
  - Display: resolution, display size, brightness and quality.
  - Input
  - Audio
  - Security: connection code, and the paired iPads with their names and
    models.
  - General: permissions, staying awake while connected, and login.
- **Local cursor.** The pointer is drawn on the iPad from a separate position
  stream, about 1 ms behind the Mac, instead of travelling inside the video.
- **Metal renderer.** The iPad decodes and shows each frame the moment it is
  ready. It never lets more than about 100 ms of frames wait for the decoder,
  so a slower iPad skips ahead instead of falling behind. The system video
  layer is available as an option.
- **Portrait.** Rotate the iPad, and the Mac display becomes a vertical
  monitor.
- **ProMotion.** Up to 120 Hz on iPad Pro, or a fixed 60 Hz.
- **Several iPads at once.** Each iPad is its own display (not yet tested
  with two iPads). Audio goes to the first iPad that turns it on.
- **Works next to Sidecar and DisplayLink.** Another iPad on Sidecar, an
  iPhone on the cable, or a DisplayLink monitor does not get in the way.
- **Opens at login**, so the Mac's screen appears on the iPad after a restart.

## Requirements

- A Mac running macOS 14 Sonoma or later. Apple Silicon is recommended.
- An iPad running iPadOS 17 or later, with a USB‑C **data** cable.
- Xcode 16 or later to build. The iPad app can be signed with a free Apple ID,
  but a build signed that way expires after 7 days.

## Install

### Ready-made package

Build the package with:

```bash
scripts/build-ipa.sh
```

```bash
SIGN_IDENTITY=- scripts/build-dmg.sh
```

This produces `dist/WiredDisplay-<version>.ipa` (the iPad app) and
`dist/WiredDisplay-<version>.dmg` (the Mac app and audio driver). Sideload the
IPA with [AltStore](https://altstore.io) or SideStore. AltStore re-signs it
with your own Apple ID and renews it in the background.

[docs/share/PANDUAN-INSTALASI.txt](docs/share/PANDUAN-INSTALASI.txt) is a
step-by-step guide in Indonesian.

### From source

```bash
# Mac host: builds, signs and installs ~/Applications/WiredDisplayHost.app
scripts/build-host-app.sh
open ~/Applications/WiredDisplayHost.app
```

```bash
# iPad app: builds, signs with your team and installs on the iPad on USB
scripts/install-ipad-app.sh
```

The iPad script finds your team from the "Apple Development" certificate in
the keychain and uses the first iPad connected over USB. Set `TEAM_ID`,
`DEVICE` and `BUNDLE_PREFIX` to override these.

### Sharpest picture

Set the iPad's **Display Zoom to Default** (Settings › Display & Brightness).
"More Space" makes the iPad report a larger panel than it has, so the Mac
encodes about 35% more pixels and the iPad scales them down again. Default
streams 1:1 to the panel. Measured on an iPad Air 13″: encode went from 16 to
12 ms, and display latency from about 40 to 30 ms.

### First run

1. Open WiredDisplay on the Mac. It lives in the menu bar.
2. Grant **Screen Recording**. Grant **Accessibility** too if you want input
   from the iPad.
3. Connect the iPad and open the WiredDisplay app on it.
4. Check that the 6-digit code is the same on both screens, then accept it on
   both.
5. Optional: in the menu bar panel, Input tab, turn on **Allow Input from
   iPad**.
6. Optional: choose a **Quality** preset.

For audio, run `Audio Driver/Install Audio Driver.command` from the DMG. It
asks for your admin password. Then pick **iPad Speaker** or **iPad
Microphone** in Sound settings.

## How it works

```
Mac (WiredDisplayHost)                              iPad (WiredDisplay)
CGVirtualDisplay ─► ScreenCaptureKit ─► VideoToolbox HEVC ─┐
CoreAudio loopback ───────────────────────────────────────┤  usbmuxd over USB‑C
CGEvent injection ◄── touch · keys · trackpad · gestures ──┤  encrypted, framed
                                                           └─► VideoToolbox decode ─► Metal
```

| Path | What's there |
|---|---|
| `macOSHost/Host` | Menu-bar app: display, capture, encoder, input injection, audio bridge |
| `macOSHost/Display/CVirtualDisplay` | Objective-C shim for the private `CGVirtualDisplay` API. It is resolved at runtime and fails closed. |
| `iPadOSClient/WiredDisplayClient` | iPad app (SwiftUI and UIKit) |
| `Shared/` | Swift packages for the protocol, session crypto, usbmux, transport, video, geometry and audio |
| `MacVirtualDevices/` | The audio driver (AudioServerPlugIn) |
| `Tests/Unit` | Unit tests. Run them with `swift test` or `scripts/verify.sh`. |
| `docs/` | Decisions, change log, bug log, risks and the capability matrix |

## Limitations

- **Private and undocumented APIs.** `CGVirtualDisplay` and the trackpad
  gesture event layout are not public. A future macOS release may break
  them. The app is not sandboxed and not notarized.
- **Three- and four-finger trackpad swipes** stay with iPadOS and never reach
  the app.
- **After a Mac reboot**, the iPad sometimes does not show up on USB until the
  cable is unplugged for about 10 seconds and plugged back in. This is
  platform behaviour (BUG‑037).
- **Free Apple ID signing** expires after 7 days. AltStore renews it.
- **Older iPads** may not decode 4:4:4 or 10-bit video, or not fast enough.
  If an iPad keeps failing or falling behind, the Mac drops to 4:2:0 and
  then to 8-bit for that iPad automatically, and shows the limit in the menu
  bar panel. Only an iPad Air 13″ (M2) has been tested.
- **The iPad cannot wake a sleeping Mac.** During system sleep the Mac app
  and the USB connection are frozen, so wake it with its own keyboard or
  mouse. Turn on **Keep the Mac awake** to keep it from sleeping on its own
  while an iPad is connected. Display sleep and the screensaver can be
  woken from the iPad.

## License

WiredDisplay is free software, released under the
[GNU General Public License v3.0](LICENSE). You may use, study, share and
modify it. If you distribute a modified version, it must also be under the
GPL-3.0, with its source available.

## Status

This is a personal project, tested on one Mac mini with an iPad Air 13″ (M2).
Design notes are in [docs/DECISIONS.md](docs/DECISIONS.md), and the history of
changes is in [docs/CHANGELOG.md](docs/CHANGELOG.md). Raw hardware test logs
are kept out of this repository.

---

🤖 Built with [Claude Code](https://claude.com/claude-code)
