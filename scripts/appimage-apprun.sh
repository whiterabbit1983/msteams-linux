#!/bin/sh
# Installed as AppDir/AppRun (linuxdeploy may wrap it as AppRun.wrapped).
set -eu
APPDIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export APPDIR
export PATH="$APPDIR/usr/bin:$PATH"
export LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export WEBKIT_EXEC_PATH="$APPDIR/usr/libexec/webkit2gtk-4.1"
export WEBKIT_INJECTED_BUNDLE_PATH="$APPDIR/usr/lib/webkit2gtk-4.1/injected-bundle"
for hook in "$APPDIR"/apprun-hooks/*.sh; do
  [ ! -f "$hook" ] || . "$hook"
done
if [ "${1:-}" = "--webrtc-smoke" ]; then
  export MSTEAMS_WEBRTC_SYNTHETIC=1
  exec "$APPDIR/usr/libexec/msteams-webrtc-smoke"
fi
# Do not relocate Tauri's generic AppRun to usr/: it derives its desktop-file
# search directory from its own executable path, not from this APPDIR value.
exec "$APPDIR/usr/bin/msteams-tauri" "$@"
