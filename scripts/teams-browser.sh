#!/bin/sh
# Run Teams with the browser's shipped WebRTC stack and normal site permissions.
set -eu
for browser in google-chrome-stable google-chrome microsoft-edge-stable microsoft-edge chromium chromium-browser; do
    if command -v "$browser" >/dev/null 2>&1; then
        exec "$browser" --app=https://teams.microsoft.com/
    fi
done
printf '%s\n' 'Install Google Chrome, Microsoft Edge, or Chromium and run this launcher again.' >&2
exit 1
