#!/usr/bin/env bash
# Ubuntu/Debian native build dependencies. Run after apt-get update:
#   sudo bash scripts/install-webrtc-deps.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/webrtc-packages.sh
source "$ROOT/scripts/webrtc-packages.sh"

# Unlike apt-get download, install resolves the full dependency graph, including
# runtime libraries and all private pkg-config dependencies of the dev packages.
apt-get install -y --no-install-recommends \
  "${WEBKIT_BUILD_TOOLS[@]}" \
  "${WEBKIT_DEV_PACKAGES[@]}" \
  "${WEBKIT_MEDIA_PACKAGES[@]}"
