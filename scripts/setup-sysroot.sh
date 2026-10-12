#!/usr/bin/env bash
#
# Builds a local pkg-config "sysroot" out of Ubuntu `-dev` packages so that this
# Tauri app can be compiled WITHOUT root / without installing system packages.
#
# It downloads the required `*-dev` packages with `apt-get download` (which does
# not need root), extracts them into ./.tauri-sysroot, and symlinks the runtime
# libraries so the linker can resolve the `-lfoo` flags produced by pkg-config.
#
# On a normal machine with sudo you should instead install the packages listed
# in the README and skip this script. This is a fallback for locked-down boxes.
#
# Usage:  ./scripts/setup-sysroot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="${SYSROOT:-$ROOT/.tauri-sysroot}"
DEB_CACHE="$SYSROOT/.debs"

ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
DEB_DIR="/var/lib/dpkg/info"

echo "==> sysroot: $SYSROOT"

mkdir -p "$DEB_CACHE"
cd "$DEB_CACHE"

PKGS_FILE="$SYSROOT/.packages.txt"

if [[ ! -s "$PKGS_FILE" ]]; then
  echo "==> resolving -dev dependencies (this can take a moment)…"
  {
    printf '%s\n' \
      libwebkit2gtk-4.1-dev \
      libgtk-3-dev \
      libsoup-3.0-dev \
      libjavascriptcoregtk-4.1-dev
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      libwebkit2gtk-4.1-dev 2>/dev/null \
      | grep -E '^[a-zA-Z0-9]' | grep -v ':' | grep -E '\-dev$'
  } | sort -u > "$PKGS_FILE"
fi

echo "==> downloading $(wc -l < "$PKGS_FILE") dev packages…"
while read -r pkg; do
  [[ -z "$pkg" ]] && continue
  apt-get download "$pkg" >/dev/null 2>&1 || echo "    (skipped $pkg)"
done < "$PKGS_FILE"

echo "==> extracting…"
for deb in ./*.deb; do
  [[ -e "$deb" ]] || continue
  dpkg-deb -x "$deb" "$SYSROOT"
done

echo "==> linking runtime libraries…"
shopt -s nullglob
for lib in /usr/lib/"$ARCH"/*.so /usr/lib/"$ARCH"/*.so.*; do
  base="$(basename "$lib")"
  dest="$SYSROOT/usr/lib/$ARCH/$base"
  [[ -e "$dest" ]] && continue
  ln -sf "$lib" "$dest"
done

# The upstream Tauri AppImage bundler runs linuxdeploy's gtk plugin, which asks
# pkg-config (respecting PKG_CONFIG_SYSROOT_DIR) for the runtime data directories
# below. Because this sysroot only contains `-dev` packages, those directories
# are missing/empty, so link the real ones from the system.
echo "==> linking GLib/Gio runtime data…"
link_runtime_dir() {
  local rel="$1"
  local src="/$rel"
  local dest="$SYSROOT/$rel"
  [[ -e "$src" ]] || return 0
  [[ -L "$dest" ]] && return 0
  [[ -d "$dest" ]] && rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  ln -sfn "$src" "$dest"
}
link_runtime_dir "usr/share/glib-2.0/schemas"
link_runtime_dir "usr/lib/$ARCH/gio/modules"
link_runtime_dir "usr/lib/$ARCH/girepository-1.0"

echo
echo "Done. Build with:  ./scripts/build.sh"
