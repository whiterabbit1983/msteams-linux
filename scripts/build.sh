#!/usr/bin/env bash
#
# Builds (or runs) the Tauri app, transparently using the local sysroot created
# by scripts/setup-sysroot.sh when it is present.
#
# Usage:
#   ./scripts/build.sh            # debug build
#   ./scripts/build.sh --release # release build
#   ./scripts/build.sh --run     # debug build + run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/.tauri-sysroot"
WEBKIT_PREFIX="$ROOT/.webrtc-webkit/install"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"

export PATH="$HOME/.cargo/bin:$PATH"

if [[ -d "$SYSROOT/usr/lib/$ARCH/pkgconfig" ]]; then
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_PATH="$SYSROOT/usr/lib/$ARCH/pkgconfig:$SYSROOT/usr/share/pkgconfig"
  export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
  export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
  export LIBRARY_PATH="$SYSROOT/usr/lib/$ARCH:/usr/lib/$ARCH"
  echo "==> using local sysroot: $SYSROOT"
else
  echo "==> no local sysroot found, relying on system dev packages"
fi

if [[ -d "$WEBKIT_PREFIX/lib" ]]; then
  export LD_LIBRARY_PATH="$WEBKIT_PREFIX/lib:$SYSROOT/usr/lib/$ARCH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export WEBKIT_EXEC_PATH="$WEBKIT_PREFIX/libexec/webkit2gtk-4.1"
  export WEBKIT_INJECTED_BUNDLE_PATH="$WEBKIT_PREFIX/lib/webkit2gtk-4.1/injected-bundle"
  GST_PLUGINS="$SYSROOT/usr/lib/$ARCH/gstreamer-1.0"
  GST_HELPERS="$SYSROOT/usr/lib/$ARCH/gstreamer1.0/gstreamer-1.0"
  if [[ -d "$GST_PLUGINS" ]]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$GST_PLUGINS"
    export GST_PLUGIN_PATH_1_0="$GST_PLUGINS"
    export GST_PLUGIN_SCANNER_1_0="$GST_HELPERS/gst-plugin-scanner"
  fi
  echo "==> using WebRTC-enabled WebKitGTK: $WEBKIT_PREFIX"
fi

cd "$ROOT/src-tauri"

case "${1:-}" in
  --run)
    shift
    cargo run "$@"
    ;;
  *)
    cargo build "$@"
    ;;
esac
