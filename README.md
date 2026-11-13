# Microsoft Teams — Tauri desktop wrapper

A tiny native shell around the [Microsoft Teams](https://teams.microsoft.com) web
client, built with [Tauri v2](https://tauri.app). It gives you a real desktop
window, a proper app icon, persistent sign-in, in-app authentication popups and
hands external links off to your browser — without bundling the official
(electron-based) Teams client.

> Unofficial project. Not affiliated with, endorsed by or supported by Microsoft.

## Features

- **Native window** that loads `https://teams.microsoft.com`.
- **External links** (`http`/`https` to non-Microsoft hosts) open in your default
  browser instead of taking over the app.
- **In-app auth popups** — OAuth windows opened by Teams (`window.open`,
  `target="_blank"` to `login.microsoftonline.com`, …) are opened as separate
  app windows so the sign-in flow completes inside the wrapper.
- **Media & notifications** — camera, microphone, screen-share, media keys and
  notification permissions are granted automatically so notifications work and
  the call UI can request devices.

  > Calls/messages only actually connect on Linux where the system WebKitGTK was
  > built with WebRTC. See [Calls / WebRTC on Linux](#calls--webrtc-on-linux).
- **Native notifications** — Teams' web notifications are bridged to desktop
  notifications through `tauri-plugin-notification`.
- **Tray icon with unread badge** — closing the window hides the app to the
  system tray, whose icon shows a red badge with the unread message count
  (driven by Teams' web notifications and the unread counter it puts in
  `document.title`). Left-clicking the tray icon restores the window,
  right-clicking opens the menu.
- **Persistent session** — the WebView data directory lives under the app data
  directory, so you stay signed in between launches.
- **Third-party cookies on Linux** — WebKitGTK's default cookie accept policy is
  *exclusively from the main document's domain*, which drops the cookies Teams
  uses during sign-in. The wrapper switches the policy to *always* (and turns
  Intelligent Tracking Prevention off) before the first request leaves, so
  Teams' third-party-cookie probe succeeds.
- **Cross-platform** — Linux, macOS and Windows (Tauri v2 runtime).

## Why the "third-party cookies" error page used to appear

Teams checks third-party cookie support at start-up by loading
`https://teams.public.onecdn.static.microsoft/…/report-third-party-cookies.html`
in a **hidden iframe** and asking that page to set a `SameSite=None` cookie. If
the probe fails, Teams immediately navigates to the very same URL — which is the
error dialog (and the MS link opened in your browser) you saw.

WebKitGTK emits its `decide-policy` signal for **every frame**, and Tauri's
`on_navigation` is a thin wrapper around it. The wrapper used to treat the probe
iframe exactly like a user-clicked link: because the OneCDN host was not in
`TRUSTED_HOSTS` the navigation was rejected *and* handed to the system browser, so
the probe never ran and Teams concluded the browser was broken.

The fix has three parts:

1. on Linux real external anchor clicks use an injected capture handler and an
   explicitly permitted native command, rather than `on_navigation`. Hidden
   sub-frames and authentication redirects are left alone. A late WebKitGTK
   `decide-policy` callback is not sufficient: Tauri's earlier handler can
   consume the signal before our callback runs;
2. `static.microsoft` (the OneCDN bucket Teams serves itself from) is part of
   `TRUSTED_HOSTS`, so Teams' own report pages stay inside the app;
3. the third-party cookie settings are applied *before* the window navigates to
   Teams. Navigation waits until WebKitGTK's network process confirms the new
   cookie policy, so the first cookie probe cannot race the asynchronous update.

## Layout

```
.
├── .github/workflows/release.yml  # CI: checks + AppImage -> GitHub release
├── dist/                     # minimal placeholder page (bundled, unused at runtime)
├── package.json              # Tauri CLI scripts
├── package-lock.json         # pinned npm deps (required by CI's `npm ci`)
├── scripts/
│   ├── setup-sysroot.sh      # root-less build deps (fallback, see below)
│   ├── build.sh              # build/run helper that wires up the sysroot
│   ├── build-webrtc-webkit.sh # local WebKitGTK with WebRTC and media support
│   ├── check-webrtc-deps.sh  # validate the complete GTK/media pkg-config stack
│   ├── webrtc-packages.sh    # shared WebKitGTK dependency manifest
│   ├── install-webrtc-deps.sh # install the full APT dependency graph (CI)
│   └── build-appimage.sh     # Linux AppImage packaging for the sysroot setup
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs              # declares the app commands for the Tauri ACL
    ├── tauri.conf.json       # app metadata, bundle + window config
    ├── capabilities/default.json
    ├── icons/                 # generated app icons
    └── src/
        ├── main.rs
        └── lib.rs            # all the wrapper logic
```

## Prerequisites

- [Rust](https://rustup.rs) (stable) and Cargo.
- [Node.js](https://nodejs.org) 18+ (only for the Tauri CLI).
- The Tauri **system dependencies** for your platform, most importantly
  `webkit2gtk-4.1` and `gtk3` on Linux. On Debian/Ubuntu/Mint:

  ```bash
  sudo apt update
  sudo apt install -y libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev build-essential curl wget file libssl-dev \
      librsvg2-dev
  ```

See the [Tauri prerequisites guide](https://tauri.app/start/prerequisites/) for
macOS and Windows.

### No root / locked-down machine?

If you cannot install the `-dev` packages above, this repo can build a local
sysroot without root using `apt-get download`:

```bash
./scripts/setup-sysroot.sh   # once, downloads/extracts the -dev packages locally
./scripts/build.sh           # build (wires up the sysroot automatically)
```

`build.sh` falls back to system packages automatically when the local sysroot is
absent, so it is safe to use everywhere.

## Calls / WebRTC on Linux

Teams calls and meetings need the browser `RTCPeerConnection` API. The wrapper
asks WebKitGTK for it (`enable-webrtc` in `configure_webkit`), but that setting
is a **no-op unless the installed WebKitGTK was compiled with `ENABLE_WEB_RTC`**.
Ubuntu/Debian ship `libwebkit2gtk-4.1-0` with that option off, so
`RTCPeerConnection` is `undefined` and Teams shows:

> Something went wrong — You can't receive or make calls right now. Please try
> again by restarting the app.

Two independent reasons make this a system-level problem rather than an app bug:

- the GTK port defaults `ENABLE_WEB_RTC` to `ENABLE_EXPERIMENTAL_FEATURES`,
  which is off in the distro build (EME and WebGPU are off for the same reason);
- the `enable-webrtc` setting only flips a per-page WebCore setting, so it can
  never add a feature that was not compiled in.

Verify it directly:

```bash
# in the app console (MSTEAMS_DEBUG=1) or a WebKitGTK test page
typeof RTCPeerConnection   // "undefined" on stock Ubuntu WebKitGTK
```

The wrapper cannot add WebRTC to an already installed WebKitGTK, so the project
builds a compatible local copy instead of hiding the calling error:

On Linux with sudo (also used by GitHub Actions):

```bash
sudo apt-get update
sudo bash scripts/install-webrtc-deps.sh
./scripts/build-webrtc-webkit.sh --system-deps
./scripts/build.sh --run
```

The shared manifest `scripts/webrtc-packages.sh` lists the build tools, development
packages and media plugins. `apt-get install` resolves **all** their transitive
build/runtime dependencies, rather than downloading individual dev packages.
This includes libunwind, libdw, libelf, ORC and the libnice ICE plugin.

For a locked-down Linux machine without sudo, `build-webrtc-webkit.sh` without
`--system-deps` instead downloads/extracts the manifest's full dependency graph
into the local sysroot. This fallback needs more download space.

The build enables `ENABLE_MEDIA_STREAM`, `ENABLE_WEB_RTC` and the GStreamer
WebRTC backend. Before compiling WebKitGTK, it checks the GTK/media pkg-config
modules together, compiles a small GStreamer/WebRTC header check, and configures
CMake to validate dependency versions and platform features. Use
`--configure-only` to stop after those checks. CI runs configuration in a separate
step, before the expensive compilation. This catches missing include flags early
instead of failing later with `gst/gst.h: No such file or directory`.

`build.sh` automatically points both the app and WebKit's helper processes at
this local copy. The AppImage build packages the same copy so calls
also work without replacing the system's WebKitGTK. Camera and microphone access
must be allowed by the desktop environment. For running from source on
Debian/Ubuntu/Mint, install the media runtime plugins:

```bash
sudo apt install gstreamer1.0-plugins-bad gstreamer1.0-plugins-good \
    gstreamer1.0-nice gstreamer1.0-alsa gstreamer1.0-gl gstreamer1.0-pipewire \
    gstreamer1.0-pulseaudio
```

To verify the runtime without calling a Teams contact, run the WebRTC smoke
example. It opens the camera and microphone, negotiates two local peer
connections, and requires ICE, inbound audio/video RTP and successful playback
before passing. No recording is saved and no media leaves the machine.

```bash
./scripts/build.sh --run --example webrtc-smoke
```

## AppImage

```bash
./scripts/build-appimage.sh   # produces Microsoft_Teams-x86_64.AppImage
./Microsoft_Teams-x86_64.AppImage --webrtc-smoke  # synthetic-media runtime check
```

The packaged smoke check uses generated audio/video instead of hardware devices,
but exercises the same real WebRTC, ICE, codecs and decoders. It is **disabled by
default** for release publication at the maintainer's request. Enable the
`webrtc_smoke` checkbox in a manual workflow run to execute it; if enabled, a
failure still blocks that run's publication. Release notes explicitly state
whether the check passed or was skipped. A successful build without this check
is not evidence that audio/video calls work.

When enabled, CI runs the check in a virtual display and starts PulseAudio with
a virtual null sink so WebAudio can run without a physical sound device. The check waits for positive inbound audio/video RTP counters **and**
advancing decoded playback, rather than sampling stats once after 1.5 seconds.
Failure logs include the sender/receiver counters, track states and audio context
state; a failed candidate is kept as `unverified-appimage`, not published.

This is a hand-driven packaging run because the upstream `tauri build
--bundles appimage` conflicts with the local sysroot (its gtk plugin asks
pkg-config, which returns sysroot-prefixed paths, for the runtime data
directories). The script instead calls linuxdeploy with a clean environment and
ships the pieces the webkit gtk plugin does not handle itself:

- `scripts/appimage-apprun.sh` — a launcher that sets WebKit paths relative to
  the mounted AppImage and directly executes `usr/bin/msteams-tauri`. It does
  not relocate Tauri's generic AppRun into `usr/`, which makes that helper look
  for `.desktop` files in the wrong directory,
- the local WebKitGTK/JavaScriptCore libraries, helper processes and
  injected-bundle, with no dependency on the distro WebKit build,
- the GStreamer runtime plugins, including WebRTC and audio/video support,
- `libayatana-appindicator3` (loaded by `dlopen`, invisible to linuxdeploy's
  ldd scan) with its full dependency closure.

Run `npm run tauri build -- --bundles appimage` once first if the linuxdeploy /
AppRun cache is missing (it may fail at the gtk step; that populates the cache).

### GitHub Actions

`.github/workflows/release.yml` builds and publishes the AppImage:

| Trigger | What happens |
| --- | --- |
| push tag `v*` | `fmt`/`clippy`/`tests` → build AppImage → publish a GitHub release for that tag |
| **Actions → Run workflow** | same, published as a prerelease; fill the optional `tag` input to build *and* check out that tag |
| pull request touching `src-tauri/**`, `dist/**`, `scripts/**`, `package*.json` | checks only, nothing is published |

Checks and dependency preparation run in parallel. Publication waits for both
checks and AppImage packaging to succeed. The app job installs the shared APT
dependency manifest and validates the complete GTK/media stack.
`build-appimage.sh` packages the local WebKitGTK and the system media plugins.
The result is uploaded as `Microsoft_Teams-<version>-x86_64.AppImage`.
Before publishing, CI launches the **actual app** from an unrelated empty working
directory under D-Bus/Xvfb. The gate requires a Tauri/GTK main-window startup
marker and a process that stays running for 20 seconds. This packaging/startup
check is separate from the disabled-by-default WebRTC test and does not verify
Teams sign-in or calls. A second real-app integration gate uses X11 clicks in a
controlled local HTML fixture: target-blank, same-frame Microsoft documentation
and middle-click links must reach a host browser-launcher stub exactly once,
without inherited AppImage loader paths; authentication must not be sent there.
It does not require a Teams account or a real browser session.

### Reusable WebKitGTK binaries

`.github/workflows/webkit.yml` produces a permanent, versioned dependency release
containing the installed WebKitGTK as `*.tar.gz` plus a SHA256 sidecar. App builds
download this archive instead of compiling WebKitGTK. Cache eviction no longer
forces a multi-hour rebuild. Dependency releases are marked as prereleases and
are separate from the downloadable Teams AppImage.

`scripts/webkit-profile.json` is the shared source version, source SHA256 and
CMake option manifest used by the builder and archive validator. The dependency
identity includes this profile, the package manifest and the relocatable patch.
Changing CI or build-driver plumbing alone does not invalidate it; bump
`build_revision` for other runtime-affecting build changes. Archive installation
checks the SHA256, embedded profile, required x86-64 ELF files and safe archive
paths before exposing the install. Python 3.12 or newer is required.

The dependency workflow automatically reuses a matching published archive or
installed cache. A genuinely new profile builds from source, with ccache,
CPU/cgroup/RAM-aware parallelism and a single Ninja link job. It saves compiler
cache entries even after a compile failure and the completed install before
archive publication. An explicit `bootstrap_cache_key` input can migrate a known
compatible legacy install cache without recompilation; it must not point to an
incompatible profile. The initial archive uses the same runtime options as the
already-published `build-8` AppImage, including WebRTC.

Rust workspace artifacts, npm and `~/.cache/tauri` tools are also cached. The
redundant full Tauri build used to populate tooling now runs **only on a tooling
cache miss**, not on every app build. The optional WebRTC check remains disabled
by default; see the runtime-check section above. Logs are retained for 7 days,
including on failure, and mock tests cover dependency and archive validation.
The JavaScript-based Actions use Node.js 24; the app's Node.js toolchain is
configured separately by `setup-node`. Repository write access is limited to
the dependency producer and AppImage publisher. Release publication fails if
the expected AppImage is missing.

Publishing needs no extra setup beyond the default `GITHUB_TOKEN`, since the
workflow pushes to the same repository it is triggered from.

### Measured CI timings

Ubuntu 24.04 GitHub-hosted runners, elapsed wall time (including setup and uploads):

| Measurement | Before ([run 8](https://github.com/whiterabbit1983/msteams-linux/actions/runs/43424590282)) | After ([run 9](https://github.com/whiterabbit1983/msteams-linux/actions/runs/43430830299)) |
| --- | --- | --- |
| Entire release workflow | 13 min 56 s | 10 min 14 s |
| AppImage job | 11 min 45 s | 7 min 26 s |
| Redundant Tauri tooling build | 5 min 36 s | skipped (tooling cache hit) |
| WebKit binary download, checksum/profile/ELF validation and install | installed cache used | 6 s from the permanent dependency release |
| Actual app startup gate | absent | passed, 20 s |

Run 9 includes waiting for the initial dependency archive producer. Total time
fell by about **27%**, despite adding the real application startup gate. Runner
load and cache state can change these timings. The historical WebKit source
compilation took 3 h 51 min; binary reuse avoids that compilation, rather than
making the same compilation finish in 6 seconds. The new cold-build ccache and
Ninja configuration passed Linux CMake validation, but a complete cold rebuild
was not repeated or benchmarked after this change. Neither these timings nor
the startup gate validate Teams sign-in or audio/video calls.

## Build & run

Using the Tauri CLI (the normal workflow):

```bash
npm install
npm run dev       # dev build + run
npm run build     # production bundles
```

Or with the helper script:

```bash
./scripts/build.sh            # cargo build (debug)
./scripts/build.sh --release  # cargo build --release
./scripts/build.sh --run      # build + launch
```

## Configuration

Almost everything lives in `src-tauri/src/lib.rs`:

- `TEAMS_URL` — the entry point loaded at startup.
- `TRUSTED_HOSTS` — the **allow-list** of suffixes that may load inside the app.
  Links to anything else are opened externally. Tighten/extend this if your tenant
  uses custom domains.
- `create_window` — window size, title and the navigation / popup / permission
  handlers shared by the main window and popups. The window is built on
  `about:blank` and navigated to Teams afterwards, so the WebKitGTK settings are
  in place before the first request.
- `configure_webkit` (Linux only) — reaches into the WebKitGTK webview via
  `with_webview`, turns Intelligent Tracking Prevention off and sets the cookie
  accept policy to *always* (without them Teams shows its third-party-cookie
  error page), enables `MediaCapabilities` and asks for WebRTC support (see
  [Calls / WebRTC on Linux](#calls--webrtc-on-linux)). With `MSTEAMS_DEBUG=1`
  it also prints the resulting ITP and cookie-policy state.
- `src-tauri/src/link-policy.json`, `link_policy.rs` and `injected.js` — shared
  classification for real chat-link clicks and native popups. Teams/authentication
  stay in-app; ordinary external links, including SharePoint and Microsoft docs,
  go to the system browser. The opener plugin's default JavaScript interceptor
  is disabled; `open_external_link` has its own explicit IPC permission.
- `src-tauri/src/external.rs` (Linux only) — launches `xdg-open`, then `gio open`
  as a fallback, off the UI thread. Only the child environment loses AppImage
  library/GTK paths; display, D-Bus and the host's browser PATH remain available.
  Failures appear in the terminal log and a native notification.
- `close_popups` — drops the leftover `auth-*` windows after sign-in.
- `permission_response` — which permissions are auto-granted.
- `INJECT_JS` / `src-tauri/src/injected.js` — captures real external link clicks,
  hooks the web `Notification` API and watches the title for unread counts. Its
  observer tracks only `<title>` and direct `<head>` changes, never the full
  document, editor or virtualized message list. Mock tests verify that 10,000
  body mutations cause zero title scans or native IPC calls. This removes a
  wrapper overhead source; it is not a measured Teams frame-rate improvement.
- `render_badge` — composites the red unread badge onto the tray icon.
- The tray, its menu and the hide-to-tray close behaviour are set up in `run()`.

The `set_unread_count` / `show_notification` commands are app commands: they are
declared in `src-tauri/build.rs` (which generates their `allow-*` permissions)
and granted by `src-tauri/capabilities/default.json`, together with the
Microsoft origins the app is allowed to talk to.

App metadata (name, identifier, icons, bundle targets) is in
`src-tauri/tauri.conf.json`.
