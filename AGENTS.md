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
- `MacVirtualDevices/AudioDriver/`: the HAL audio driver.
- `docs/`:
  - `CHANGELOG.md`: P1-0xx entries. Add one for every change.
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
```bash
export GIT_INDEX_FILE=$(mktemp -d)/index
git read-tree main && git rm -r -q --cached docs/evidence && T=$(git write-tree); unset GIT_INDEX_FILE
git grep -i -E '<identifier list>' $T -- .          # must print nothing
C=$(GIT_AUTHOR_NAME=sibawono GIT_AUTHOR_EMAIL=341369459+sibawono@users.noreply.github.com \
    GIT_COMMITTER_NAME=sibawono GIT_COMMITTER_EMAIL=341369459+sibawono@users.noreply.github.com \
    git commit-tree $T -p public -m "WiredDisplay x.y.z: …")
git update-ref refs/heads/public $C && git push github public:main
```
To release: bump `CFBundleShortVersionString`/`CFBundleVersion` in `scripts/build-host-app.sh` and `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the iPad `project.pbxproj`, update the guide, build the IPA and DMG, scan their contents, publish, then run `gh release create vX.Y.Z --latest dist/*.dmg dist/*.ipa docs/share/PANDUAN-INSTALASI.txt`.

## State (2026-11-23)
- v0.5.0 (build 9) is released on GitHub. Local `main` and the published `public` tree match, except `docs/evidence`.
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
