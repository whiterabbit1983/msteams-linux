#!/usr/bin/env bash
# Run with the same pkg-config/sysroot environment as the WebKitGTK build.
# Check the GTK/media stack together before CMake validates versions and ABI.
set -euo pipefail

modules=(
  glib-2.0 gio-2.0 gio-unix-2.0 gobject-2.0 gthread-2.0 gmodule-2.0
  cairo libgcrypt gpg-error libtasn1 harfbuzz harfbuzz-icu
  icu-uc icu-i18n icu-data libjpeg epoxy libxml-2.0 libpng sqlite3 zlib
  libwebp libwebpdemux gtk+-3.0 libsoup-3.0 fontconfig freetype2
  libxslt libsecret-1 libdrm gbm enchant-2 x11 xt
  wayland-client wayland-egl wayland-protocols lcms2 egl gl glesv2
  libseccomp gudev-1.0
  gstreamer-1.0 gstreamer-app-1.0 gstreamer-pbutils-1.0
  gstreamer-video-1.0 gstreamer-mpegts-1.0 gstreamer-tag-1.0
  gstreamer-gl-1.0 gstreamer-audio-1.0 gstreamer-fft-1.0
  gstreamer-webrtc-1.0 gstreamer-sdp-1.0 openssl
)

# Query modules separately so all missing modules are reported in one pass.
missing=0
for module in "${modules[@]}"; do
  if ! pkg-config --print-errors --cflags --libs "$module" >/dev/null; then
    missing=1
  fi
done
if (( missing )); then
  echo "ERROR: incomplete WebRTC development dependencies (see all errors above)." >&2
  exit 1
fi

if ! flags="$(pkg-config --print-errors --cflags "${modules[@]}")"; then
  echo "ERROR: incomplete WebRTC development dependencies (see pkg-config errors above)." >&2
  exit 1
fi
# Check library metadata too; this also exposes missing transitive .pc files.
pkg-config --print-errors --libs "${modules[@]}" >/dev/null

# A successful CMake find_library alone does not guarantee usable include paths.
# pkg-config emits shell-separated compiler flags; word splitting is intended.
# shellcheck disable=SC2086
"${CC:-cc}" $flags -x c -fsyntax-only - <<'EOF'
#define GST_USE_UNSTABLE_API
#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <openssl/ssl.h>
int main(void) { return 0; }
EOF

echo "WebRTC development dependencies: OK"
