#!/usr/bin/env bash
# Run with the same pkg-config/sysroot environment as the WebKitGTK build.
# Fail before the expensive build if a transitive dependency hides GST cflags.
set -euo pipefail

modules=(
  gstreamer-1.0 gstreamer-app-1.0 gstreamer-pbutils-1.0
  gstreamer-video-1.0 gstreamer-mpegts-1.0 gstreamer-tag-1.0
  gstreamer-gl-1.0 gstreamer-audio-1.0 gstreamer-fft-1.0
  gstreamer-webrtc-1.0 gstreamer-sdp-1.0 openssl
)

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
