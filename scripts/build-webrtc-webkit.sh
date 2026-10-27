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

"$ROOT/scripts/setup-sysroot.sh"

mkdir -p "$SYSROOT/.debs" "$WORK"
cd "$SYSROOT/.debs"
{
  apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances \
    cmake ninja-build ruby ruby-dev bison flex gperf unifdef gettext \
    libglib2.0-bin libglib2.0-dev-bin 2>/dev/null \
    | grep -E '^[a-zA-Z0-9]' | grep -v ':'
  printf '%s\n' \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    libgcrypt20-dev libgpg-error-dev \
    libharfbuzz-dev libdrm-dev libfontconfig-dev libfreetype-dev libicu-dev \
    liblcms2-dev libxslt1-dev libxml2-dev libsqlite3-dev libgudev-1.0-dev \
    libjpeg-dev libopenjp2-7-dev libpng-dev libtasn1-6-dev libwebp-dev \
    libxt-dev libenchant-2-dev libsecret-1-dev \
    libegl-dev libgl-dev libgles-dev libgbm-dev libseccomp-dev wayland-protocols \
    libssl-dev \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-good \
    gstreamer1.0-alsa \
    gstreamer1.0-gl \
    gstreamer1.0-pipewire \
    gstreamer1.0-pulseaudio
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

cmake --build "$WORK/build" --parallel "$JOBS"
cmake --install "$WORK/build"

echo
echo "WebRTC-enabled WebKitGTK installed in $PREFIX"
