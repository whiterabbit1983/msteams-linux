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
  `document.title`).
- **Persistent session** — the WebView data directory lives under the app data
  directory, so you stay signed in between launches.
- **Third-party cookies on Linux** — WebKitGTK blocks third-party cookies by
  default, which makes Teams redirect to its
  `report-third-party-cookies.html` error page. The wrapper reaches into the
  WebKitGTK webview and switches the cookie accept policy to *always* and turns
  Intelligent Tracking Prevention off so Teams loads normally.
- **Cross-platform** — Linux, macOS and Windows (Tauri v2 runtime).

## Layout

```
.
├── dist/                     # minimal placeholder page (bundled, unused at runtime)
├── package.json              # Tauri CLI scripts
├── scripts/
│   ├── setup-sysroot.sh      # root-less build deps (fallback, see below)
│   ├── build.sh              # build/run helper that wires up the sysroot
│   └── build-appimage.sh     # Linux AppImage packaging (see below)
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
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

To get working calls you need a WebKitGTK built with WebRTC, for example:

```bash
# build WebKit from https://webkit.org with the GTK port and
#   -DENABLE_MEDIA_STREAM=ON -DENABLE_WEB_RTC=ON
# (or -DENABLE_EXPERIMENTAL_FEATURES=ON) and point the app at it, e.g.
LD_LIBRARY_PATH=/path/to/webkit/lib \
WEBKIT_EXEC_PATH=/path/to/webkit/libexec/webkit2gtk-4.1 \
  ./scripts/build.sh --run
```

This is a known WebKitGTK/distro limitation, not something the wrapper can
patch around. Messaging, files and the rest of Teams work normally without it.

## AppImage

```bash
./scripts/build-appimage.sh   # produces Microsoft_Teams-x86_64.AppImage
```

This is a hand-driven packaging run because the upstream `tauri build
--bundles appimage` conflicts with the local sysroot (its gtk plugin asks
pkg-config, which returns sysroot-prefixed paths, for the runtime data
directories). The script instead calls linuxdeploy with a clean environment and
ships the pieces the webkit gtk plugin does not handle itself:

- `~/.cache/tauri/AppRun-x86_64` — the Tauri AppRun (it chdir's into
  `$APPDIR/usr`, which the gtk plugin's `././lib/...` rewrite relies on),
- `/usr/lib/<arch>/webkit2gtk-4.1/` — the WebKit helper processes and
  injected-bundle, without which the app exits with *"Unable to spawn a new
  child process"*,
- `libayatana-appindicator3` (loaded by `dlopen`, invisible to linuxdeploy's
  ldd scan) with its full dependency closure.

Run `npm run tauri build -- --bundles appimage` once first if the linuxdeploy /
AppRun cache is missing (it may fail at the gtk step; that populates the cache).

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
  handlers shared by the main window and popups.
- `configure_webkit` (Linux only) — reaches into the WebKitGTK webview via
  `with_webview` and re-enables third-party cookies (without which Teams shows
  its third-party-cookie error page), enables `MediaCapabilities` and asks for
  WebRTC support (see [Calls / WebRTC on Linux](#calls--webrtc-on-linux)).
- `permission_response` — which permissions are auto-granted.
- `INJECT_JS` — script injected into the Teams pages: it hooks the web
  `Notification` API, watches `document.title` for the `(N)` unread counter and
  forwards both to the `set_unread_count` / `show_notification` commands.
- `render_badge` — composites the red unread badge onto the tray icon.
- The tray, its menu and the hide-to-tray close behaviour are set up in `run()`.

App metadata (name, identifier, icons, bundle targets) is in
`src-tauri/tauri.conf.json`.
