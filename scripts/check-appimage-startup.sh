#!/usr/bin/env bash
# Linux-only packaging gate. Launch the real app, not the optional WebRTC example.
set -euo pipefail
IMAGE="$(readlink -f "${1:?Usage: $0 path/to/app.AppImage}")"
LOG="$PWD/startup-smoke.log"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MSTEAMS_STARTUP_CHECK=1
export LIBGL_ALWAYS_SOFTWARE=1

# A file-manager launch need not use the AppImage's directory as its cwd.
# Start from an empty, unrelated directory to catch desktop-file lookup errors.
cd "$WORK"
set +e
timeout --kill-after=5s 20s dbus-run-session -- xvfb-run -a \
  "$IMAGE" --appimage-extract-and-run 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"
set -e
if [[ "$status" != 124 ]]; then
  echo "ERROR: AppImage exited before the startup-check deadline (status $status)" >&2
  exit 1
fi
if ! grep -Fq 'MSTEAMS_STARTUP_OK' "$LOG"; then
  echo "ERROR: AppImage did not create the Tauri/GTK main window" >&2
  exit 1
fi
if grep -Eq 'No \.desktop files found|error while running the Microsoft Teams desktop application' "$LOG"; then
  echo "ERROR: AppImage reported a launcher or application startup failure" >&2
  exit 1
fi
echo "AppImage startup: main window created; app stayed running for 20 seconds"
