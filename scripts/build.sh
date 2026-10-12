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
