#!/usr/bin/env bash
#
# Builds a self-contained Linux AppImage for this Tauri app.
#
# The upstream Tauri AppImage bundler (`tauri build --bundles appimage`) runs
# linuxdeploy's gtk plugin, which is confused by our root-less `.tauri-sysroot`
# (PKG_CONFIG_SYSROOT_DIR makes pkg-config return sysroot-prefixed paths). This
# script instead drives linuxdeploy by hand with a *clean* environment so it
# resolves libraries against the real system, which is what the resulting
# AppImage should bundle anyway.
#
# It also bundles the WebKitGTK helper processes (WebKitWebProcess /
# WebKitNetworkProcess / injected-bundle). The gtk plugin rewrites the compiled
# absolute path inside libwebkit2gtk from `/usr/lib/...` to `././/lib/...`,
# which the Tauri AppRun resolves relative to `$APPDIR/usr`; without those
# helpers the app exits with "Unable to spawn a new child process".
#
# Usage:  ./scripts/build-appimage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/.tauri-sysroot"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
CACHE="$HOME/.cache/tauri"

WORK="$ROOT/src-tauri/target/appimage"
APPDIR="$WORK/AppDir"
BIN="$ROOT/src-tauri/target/release/msteams-tauri"
ICON_SRC="$ROOT/src-tauri/icons/128x128.png"
OUT_NAME="Microsoft_Teams-x86_64.AppImage"

LINUXDEPLOY="${LINUXDEPLOY:-$CACHE/linuxdeploy-07333c6-x86_64.AppImage}"
APPRUN="$CACHE/AppRun-x86_64"

export PATH="$HOME/.cargo/bin:$PATH"

# --- 1. build the release binary (reusing the local sysroot when present) -----
if [[ -d "$SYSROOT/usr/lib/$ARCH/pkgconfig" ]]; then
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_PATH="$SYSROOT/usr/lib/$ARCH/pkgconfig:$SYSROOT/usr/share/pkgconfig"
  export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
  export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
  export LIBRARY_PATH="$SYSROOT/usr/lib/$ARCH:/usr/lib/$ARCH"
  echo "==> using local sysroot: $SYSROOT"
fi

echo "==> building release binary…"
( cd "$ROOT/src-tauri" && cargo build --release )
[[ -x "$BIN" ]] || { echo "ERROR: $BIN was not produced" >&2; exit 1; }

# --- 2. preflight: linuxdeploy + plugins + AppRun must be cached -------------
missing=0
for f in "$LINUXDEPLOY" \
         "$CACHE/linuxdeploy-plugin-gtk.sh" \
         "$CACHE/linuxdeploy-plugin-appimage.AppImage" \
         "$APPRUN"; do
  [[ -e "$f" ]] || { echo "ERROR: missing $f" >&2; missing=1; }
done
if [[ "$missing" -ne 0 ]]; then
  echo "Run 'npm run tauri build -- --bundles appimage' once to populate" >&2
  echo "the linuxdeploy/AppRun cache (it is allowed to fail at the gtk step)." >&2
  exit 1
fi

# --- 3. assemble a hand-made AppDir ------------------------------------------
echo "==> assembling AppDir…"
rm -rf "$APPDIR"
install -Dm755 "$BIN" "$APPDIR/usr/bin/msteams-tauri"
install -Dm755 "$APPRUN" "$APPDIR/AppRun"

mkdir -p "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/128x128/apps"
cp "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/128x128/apps/microsoft-teams.png"
cp "$ICON_SRC" "$APPDIR/microsoft-teams.png"

cat > "$APPDIR/microsoft-teams.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Microsoft Teams
Comment=Unofficial Microsoft Teams desktop wrapper
Exec=msteams-tauri
Icon=microsoft-teams
Terminal=false
Categories=Network;InstantMessaging;Chat;
StartupWMClass=microsoft-teams
EOF
cp "$APPDIR/microsoft-teams.desktop" \
   "$APPDIR/usr/share/applications/microsoft-teams.desktop"

# WebKitGTK helper processes (relative to $APPDIR/usr, matching the gtk plugin's
# `/usr` -> `././` rewrite inside libwebkit2gtk).
HELPER_SRC="/usr/lib/$ARCH/webkit2gtk-4.1"
[[ -d "$HELPER_SRC" ]] || { echo "ERROR: $HELPER_SRC not found" >&2; exit 1; }
mkdir -p "$APPDIR/usr/lib/$ARCH"
cp -a "$HELPER_SRC" "$APPDIR/usr/lib/$ARCH/"

# The tray icon is loaded through dlopen ("libayatana-appindicator3.so.1"),
# which linuxdeploy does not see via ldd. Copy the real libraries (linuxdeploy
# only preserves dangling symlinks otherwise) together with everything they
# link against, so the AppImage tray works without system libayatana.
for libind in libayatana-appindicator3.so.1 libappindicator3.so.1; do
  src="/usr/lib/$ARCH/$libind"
  [[ -e "$src" ]] || continue
  real="$(readlink -f "$src")"
  cp -a "$real" "$APPDIR/usr/lib/$(basename "$real")"
  cp -a "$src" "$APPDIR/usr/lib/$libind"
  ldd "$real" 2>/dev/null \
    | grep -oE '(/[^ ]+)\.so(\.\S*)?' \
    | while read -r dep; do
        base="$(basename "$dep")"
        [[ -e "$APPDIR/usr/lib/$base" ]] && continue
        # copy the SONAME entry (often a symlink) preserving its name,
        # then the real target file so the link is not dangling
        cp -a "$dep" "$APPDIR/usr/lib/$base" 2>/dev/null || true
        dep_real="$(readlink -f "$dep")"
        [[ -e "$APPDIR/usr/lib/$(basename "$dep_real")" ]] \
          || cp -a "$dep_real" "$APPDIR/usr/lib/$(basename "$dep_real")" 2>/dev/null || true
      done
done

# --- 4. run linuxdeploy in a clean environment -------------------------------
echo "==> running linuxdeploy (bundling GTK + dependencies)…"
rm -f "$WORK"/*.AppImage
cd "$WORK"
PATH="$CACHE:$PATH" \
APPIMAGE_EXTRACT_AND_RUN=1 \
OUTPUT="$OUT_NAME" \
env -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_PATH \
    -u PKG_CONFIG_ALLOW_SYSTEM_CFLAGS -u PKG_CONFIG_ALLOW_SYSTEM_LIBS -u LIBRARY_PATH \
  "$LINUXDEPLOY" --appdir "$APPDIR" --plugin gtk --output appimage

produced="$(find "$WORK" -maxdepth 1 -name '*.AppImage' | head -1)"
[[ -n "$produced" ]] || { echo "ERROR: linuxdeploy produced no AppImage" >&2; exit 1; }

DEST="$ROOT/$(basename "$produced")"
mv -f "$produced" "$DEST"

echo
echo "Done: $DEST ($(du -h "$DEST" | cut -f1))"
