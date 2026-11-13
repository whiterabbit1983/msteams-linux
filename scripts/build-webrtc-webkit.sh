#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/.tauri-sysroot"
WORK="$ROOT/.webrtc-webkit"
PREFIX="$WORK/install"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
BUNDLE="$ROOT/scripts/webkit-bundle.py"
VERSION="$(python3 "$BUNDLE" version)"
SHA256="$(python3 "$BUNDLE" source-sha256)"
JOBS="${JOBS:-$(python3 "$BUNDLE" jobs)}"
# WebKit 2.48 reads these environment variables when it defines Ninja pools.
export WEBKIT_NINJA_LINK_MAX="${WEBKIT_NINJA_LINK_MAX:-1}"
export WEBKIT_NINJA_COMPILE_MAX="${WEBKIT_NINJA_COMPILE_MAX:-$JOBS}"
USE_SYSROOT=1
CONFIGURE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --system-deps) USE_SYSROOT=0 ;;
    --configure-only) CONFIGURE_ONLY=1 ;;
    *) echo "Usage: $0 [--system-deps] [--configure-only]" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
if (( USE_SYSROOT )); then
  "$ROOT/scripts/setup-sysroot.sh"
  # shellcheck source=scripts/webrtc-packages.sh
  source "$ROOT/scripts/webrtc-packages.sh"
  mkdir -p "$SYSROOT/.debs"
  cd "$SYSROOT/.debs"
  {
    # Resolve all roots, not only GST core/base. Include runtime packages too:
    # extracting dev packages without their runtime .so targets is not enough.
    printf '%s\n' "${WEBKIT_BUILD_TOOLS[@]}" "${WEBKIT_DEV_PACKAGES[@]}" "${WEBKIT_MEDIA_PACKAGES[@]}"
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances \
      "${WEBKIT_BUILD_TOOLS[@]}" "${WEBKIT_DEV_PACKAGES[@]}" "${WEBKIT_MEDIA_PACKAGES[@]}" \
      | grep -E '^[a-zA-Z0-9]' | grep -v ':'
  } | sort -u > "$WORK/build-packages.txt"

  while read -r pkg; do
    [[ -z "$pkg" ]] && continue
    apt-get download "$pkg" >/dev/null 2>&1 || {
      echo "ERROR: could not download $pkg" >&2
      exit 1
    }
  done < "$WORK/build-packages.txt"
  for deb in ./*.deb; do
    dpkg-deb -x "$deb" "$SYSROOT"
  done

  export PATH="$SYSROOT/usr/bin:$HOME/.cargo/bin:$PATH"
  export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
  export PKG_CONFIG_PATH="$SYSROOT/usr/lib/$ARCH/pkgconfig:$SYSROOT/usr/share/pkgconfig"
  export PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1
  export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
  export LIBRARY_PATH="$SYSROOT/usr/lib/$ARCH:/usr/lib/$ARCH"
  export LD_LIBRARY_PATH="$SYSROOT/usr/lib/$ARCH:$SYSROOT/lib/$ARCH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export RUBYLIB="$SYSROOT/usr/lib/ruby/vendor_ruby/3.2.0:$SYSROOT/usr/lib/ruby/vendor_ruby:$SYSROOT/usr/lib/ruby/3.2.0:$SYSROOT/usr/lib/$ARCH/ruby/3.2.0${RUBYLIB:+:$RUBYLIB}"
else
  echo "==> using native system dependencies (no rootless sysroot)"
fi

# CMake can find GST libraries even when pkg-config fails and loses the cflags.
# Check every required pkg-config module, then compile the GST/WebRTC headers.
bash "$ROOT/scripts/check-webrtc-deps.sh"

TARBALL="$WORK/webkitgtk-$VERSION.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
  curl -fL --retry 3 \
    "https://webkitgtk.org/releases/webkitgtk-$VERSION.tar.xz" \
    -o "$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum --check

if [[ ! -d "$WORK/webkitgtk-$VERSION" ]]; then
  tar -xJf "$TARBALL" -C "$WORK"
fi

PATCH="$ROOT/scripts/webkitgtk-relocatable.patch"
if patch --dry-run --silent -p1 -d "$WORK/webkitgtk-$VERSION" < "$PATCH"; then
  patch --silent -p1 -d "$WORK/webkitgtk-$VERSION" < "$PATCH"
elif ! patch --dry-run --silent --reverse -p1 -d "$WORK/webkitgtk-$VERSION" < "$PATCH"; then
  echo "ERROR: could not apply $PATCH" >&2
  exit 1
fi

CMAKE_OPTIONS=()
while IFS= read -r option; do
  CMAKE_OPTIONS+=("$option")
done < <(python3 "$BUNDLE" options)
cmake -S "$WORK/webkitgtk-$VERSION" -B "$WORK/build" -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" "${CMAKE_OPTIONS[@]}"

if (( CONFIGURE_ONLY )); then
  echo "WebKitGTK dependency validation and CMake configuration: OK"
  exit 0
fi
cmake --build "$WORK/build" --parallel "$JOBS"
cmake --install "$WORK/build"

echo
echo "WebRTC-enabled WebKitGTK installed in $PREFIX"
