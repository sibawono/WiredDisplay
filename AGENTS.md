# AGENTS.md — WiredDisplay

WiredDisplay turns an iPad into a wired USB‑C display for a Mac (often a headless Mac mini). It has a macOS menu-bar host and an iPad client. Video, audio and input all travel over usbmuxd only. The owner writes Indonesian; reply in Indonesian.

## Layout
- `macOSHost/Host/`: the host app (SwiftPM product `WiredDisplayHost`).
  - `HostController` and `HostFleet`: one controller per iPad.
  - `VideoEncoder`: HEVC; the 4:2:0 lanes use `ChromaConverter`, a filtered GPU conversion.
  - `CaptureEngine`, `InputInjector`, `CursorEcho`, `BrightnessKeys` (one shared event tap on its own thread).
  - Audio: `AudioRouter` and `HostAudioBridge` (speaker FIFO off the IO thread).
  - Menu-bar panel: `StatusPanel`, `GlassPopover` (Liquid Glass panel), `NativeControls`; wired up in `main.swift`.
- `iPadOSClient/WiredDisplayClient/`: the iPad app.
  - `ClientSession`, `MetalVideoRenderer` (default renderer), `VideoView` (touch, keyboard, local cursor), `ClientAudio`.
- `Shared/`: protocol (framing, `SecureChannel` with Ed25519/X25519 and AES‑GCM), usbmux, video, `AudioJitterBuffer` (with drift correction).
- `Shared/HostCore/` (`WDHostCore`): the host's pure decisions, unit-tested: `PowerState` and `InputGate` (what iPad input does while locked or asleep), `DisplaySpace` (Default/More/Most sizes) and `CaptureSizing`.
- `MacVirtualDevices/AudioDriver/`: the HAL audio driver.
- `docs/`:
  - `CHANGELOG.md`: P1-0xx entries. Add one for every change; take the ID from `scripts/next-change-id.sh` (parallel sessions collided before).
  - `DECISIONS.md`: D-0xx entries.
  - `BUG_LOG.md`.
  - `share/PANDUAN-INSTALASI.txt`: the user guide.

## Build, test, run
```bash
swift build --product WiredDisplayHost        # compile check
swift test                                     # unit tests (all must pass)
scripts/build-host-app.sh                      # build + sign + install ~/Applications/WiredDisplayHost.app
pkill -x WiredDisplayHost; open ~/Applications/WiredDisplayHost.app   # restart host
scripts/install-ipad-app.sh                    # iPad app (Release by default; CONFIG=Debug to override)
scripts/build-ipa.sh; SIGN_IDENTITY=- scripts/build-dmg.sh   # release artifacts in dist/
```
- CI: `.github/workflows/tests.yml` runs `swift build`, `swift test` and the protocol-vector check on GitHub's `macos-26` runner for every push to the public repo.
- The host log is `~/Library/Logs/WiredDisplayHost.log` (it rotates at 5 MB). The iPad log is `Documents/client.log` in the app container. Pull it with `xcrun devicectl device copy from --domain-type appDataContainer …`.
- Look at the panel with `open -n ~/Applications/WiredDisplayHost.app --args --render-panel-live <dir>`. This renders every tab live, because Liquid Glass does not render offscreen.
- Check the real panel with `--self-check-panel <dir>`: it opens the panel, captures each tab, and presses the slider. It moves the user's mouse for about 10 s, so warn the user first.
- Local machine details (device IDs, the bundle ID override for the free-team App ID limit) are in `docs/evidence/LOCAL-HANDOVER.md`. That folder is never published.

## Hard rules
- Commit only when the user asks. End commit messages with the user's chosen co-author line, if any.
- **Never push local `main`.** GitHub (`github` remote, sibawono/WiredDisplay) receives only a scrubbed `public` commit. Its tree is `main` minus `docs/evidence`, its author and committer are `sibawono <341369459+sibawono@users.noreply.github.com>`, and it is pushed with `git push github public:main`. See the procedure below.
- Before every push or release, scan for personal identifiers: the owner's name and e-mail, device UDIDs, the Apple team ID and its lowercase bundle-prefix form, the certificate ID, and the Mac's hostname. The exact list is in `docs/evidence/LOCAL-HANDOVER.md`. The DMG must be ad‑hoc signed (`SIGN_IDENTITY=-`).
- Publishing a GitHub release needs the user's explicit "yes".
- Never enter passwords; the user runs sudo commands. Do not disable SIP, FileVault or TCC. There is no Wi‑Fi fallback. Never change the main display or mirroring. Input is off by default (D-006).
- Do not touch other projects.

### Publishing procedure
Run `scripts/publish-public.sh "WiredDisplay x.y.z: …"`: it builds the tree, scans it (the list comes from `LOCAL-HANDOVER.md`), shows the diff, and pushes after a confirmation. Agents may be blocked from pushing; then the user runs it. The steps it performs:
```bash
export GIT_INDEX_FILE=$(mktemp -d)/index
git read-tree main && git rm -r -q --cached docs/evidence && T=$(git write-tree); unset GIT_INDEX_FILE
git grep -i -E '<identifier list>' $T -- .          # must print nothing
C=$(GIT_AUTHOR_NAME=sibawono GIT_AUTHOR_EMAIL=341369459+sibawono@users.noreply.github.com \
    GIT_COMMITTER_NAME=sibawono GIT_COMMITTER_EMAIL=341369459+sibawono@users.noreply.github.com \
    git commit-tree $T -p public -m "WiredDisplay x.y.z: …")
git update-ref refs/heads/public $C && git push github public:main
```
To release: bump `CFBundleShortVersionString`/`CFBundleVersion` in `scripts/build-host-app.sh` and `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the iPad `project.pbxproj`, update the guide, build the IPA and DMG, scan their contents, publish, then run `gh release create vX.Y.Z --latest dist/*.dmg dist/*.ipa docs/share/PANDUAN-INSTALASI.txt`. Publishing the release also sends its IPA to SideStore Connect through `.github/workflows/sidestore.yml` (see `docs/SIDESTORE.md`). The IPA asset must be named `WiredDisplay-<version>.ipa`.

With every release, update the website to that release in the same step (owner: "selalu sesuaikan juga build releasenya dan what's new in [build version]"). The site's source is a separate project. Follow "At each release" in its `README.md`:
1. Set `VERSION` in its `build.py`.
2. Rewrite the `new.*` and `panel.hl.*` text in EN and ID from this release's CHANGELOG entries.
3. Update the DMG and IPA sizes and `hero.badge`.
4. Use screenshots taken from the released build.

Unreleased work on `main` stays off the site. Deploy only on the owner's yes.

## State (2026-11-26)
- v0.5.4 (build 13) is built and ready for release.
- 0.5.4 adds (P1-079 to P1-080): hybrid USB-C + encrypted local Wi-Fi (`NWFramedConnection`, Bonjour `_wireddisplay._tcp`, `SecureChannel` AES-256-GCM with mandatory SAS pairing on Wi-Fi, live Connection picker `USB-C` / `Auto` / `Wi-Fi` in General tab); adaptive bitrate controller (`AdaptiveBitrateController`); macOS 26.1/27 HiDPI physical size floor, in-place rotation, and poisoned serial retry; single-pass Annex-B encoding, live bitrate updates, and drop-replay timer; dynamic Display P3 `CAMetalLayer` colorspace (BUG-033); fix blank screen on reconnect (`clearToBlack()` render pass) and live transport status badge.
- 0.5.3 adds (P1-067 to P1-077): SideStore Connect; RT-safe audio FIFOs & lock-free HAL timestamps; Both Speakers (Mac + iPad) with sync delay & balance; Apple Pencil direct click/drag, 240 Hz strokes, palm rejection, pressure & double-tap/squeeze; Magic Keyboard global shortcuts fixes & remaps; redesigned 4-tab iPad Controls panel (Display Space, Quality, Brightness, Mac Volume & Mute, 3×2 Quick Actions, confirmed Sleep Mac, On-Screen Soft Keyboard, Live Stats HUD); GPU/encode pipeline overlap; audio dropout smoothing; PLW-06 idle-sleep fix.
- 0.5.2 adds (P1-057 to P1-063): More/Most Space when the iPad is the only screen (D-043); background audio lifecycle on the iPad; GPU 4:4:4 conversion; the `WDHostCore` module; CI; the publish scripts; UI contrast fixes; the movable, idle-fading Controls button with its own panel.
- 0.5.1 adds: the fix for GitHub issue #1 (capture no longer waits for the encoder; bounded iPad decode queue), "Keep the display on" / "Keep the Mac awake", and golden protocol vectors for a second (Android) client (`Tests/Vectors`, `docs/ANDROID_COMPATIBILITY.md`).
- New since 0.4.2:
  - the host panel redesign: a Liquid Glass panel and controls following the macOS 27 Figma kit (file `EH8VzuvPVZgEkKlgeBTvDs`);
  - the area-filter downscale for "more/most space";
  - sleep, wake, lock and screensaver handling (`docs/POWER_LOCK_WAKE.md`);
  - the "looks like" space remembered per iPad;
  - paired iPads shown with their name and model (read from lockdownd);
  - the high-risk review (`docs/HIGH_RISK_REVIEW.md`) and audit A–F (`docs/AUDIT_A_F.md`).
- The owner's priorities: 60 Hz, the lowest latency, and the best picture.

### Open items
- Not run yet: a 2-hour soak; the 20-cycle lock, sleep and screensaver series (each needs the user).
- PLW-06: the speaker tap keeps coreaudiod's idle-sleep assertion while the iPad speaker is on.
- Bitrate scaling at 120 Hz needs a ProMotion iPad to test.
- Not tested: two iPads at once, coexistence with Sidecar or DisplayLink.
- Ideas:
  - an audio dropout seen once in 30 minutes (a delivery gap);
  - the conversion takes about 4 ms, and could overlap with encoding instead of waiting for the GPU.
