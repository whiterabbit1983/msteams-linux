#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT="$ROOT/.tauri-sysroot"
WORK="$ROOT/.webrtc-webkit"
PREFIX="$WORK/install"
ARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -print-multiarch 2>/dev/null || echo x86_64-linux-gnu)"
VERSION=2.48.0
SHA256=94904a55cf12d44a4e36ceadafff02d46da73d76be9b4769f34cbfdf0eebf88e
JOBS="${JOBS:-2}"
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

cmake -S "$WORK/webkitgtk-$VERSION" -B "$WORK/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DPORT=GTK \
  -DUSE_GTK4=OFF \
  -DUSE_SOUP2=OFF \
  -DENABLE_WEB_RTC=ON \
  -DENABLE_MEDIA_STREAM=ON \
  -DUSE_GSTREAMER_WEBRTC=ON \
  -DUSE_GSTREAMER_TRANSCODER=OFF \
  -DENABLE_DOCUMENTATION=OFF \
  -DENABLE_INTROSPECTION=OFF \
  -DENABLE_WEBDRIVER=OFF \
  -DENABLE_MINIBROWSER=ON \
  -DENABLE_GAMEPAD=OFF \
  -DENABLE_SPEECH_SYNTHESIS=OFF \
  -DENABLE_JOURNALD_LOG=OFF \
  -DUSE_AVIF=OFF \
  -DUSE_JPEGXL=OFF \
  -DUSE_WOFF2=OFF \
  -DUSE_LIBBACKTRACE=OFF \
  -DUSE_LIBHYPHEN=OFF \
  -DUSE_SYSPROF_CAPTURE=OFF

if (( CONFIGURE_ONLY )); then
  echo "WebKitGTK dependency validation and CMake configuration: OK"
  exit 0
fi
cmake --build "$WORK/build" --parallel "$JOBS"
cmake --install "$WORK/build"

echo
echo "WebRTC-enabled WebKitGTK installed in $PREFIX"
