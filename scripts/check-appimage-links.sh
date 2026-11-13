#!/usr/bin/env bash
# Real Tauri/WebKit click-to-browser integration test, under Linux Xvfb only.
set -euo pipefail
if [[ "${1:-}" != --inside ]]; then
  IMAGE="$(readlink -f "${1:?Usage: $0 path/to/app.AppImage}")"
  timeout --kill-after=5s 90s dbus-run-session -- xvfb-run -a bash "$0" --inside "$IMAGE"
  exit
fi
IMAGE="$2"
LOG="$PWD/links-smoke.log"
WORK="$(mktemp -d)"
pid=""
trap 'if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/host-bin"
export MSTEAMS_CI_LINK_LOG="$WORK/browser.log"
# This stub is deliberately OUTSIDE AppDir. The real native opener must remove
# AppImage loader paths without removing the host's browser launcher from PATH.
cat > "$WORK/host-bin/xdg-open" <<'SH'
#!/bin/sh
if [ "$#" -ne 1 ]; then
  echo "Browser launcher received an unexpected argument count" >&2
  exit 90
fi
if [ -n "${APPDIR:-}${APPIMAGE:-}${LD_LIBRARY_PATH:-}${GIO_MODULE_DIR:-}${GSETTINGS_SCHEMA_DIR:-}" ]; then
  echo "Browser inherited bundled loader/GTK settings" >&2
  exit 91
fi
printf '%s\n' "$1" >> "$MSTEAMS_CI_LINK_LOG"
SH
printf '#!/bin/sh\necho "Unexpected gio fallback in link check" >&2\nexit 92\n' > "$WORK/host-bin/gio"
chmod +x "$WORK/host-bin/xdg-open" "$WORK/host-bin/gio"
export PATH="$WORK/host-bin:$PATH"
export MSTEAMS_UI_CHECK=1 LIBGL_ALWAYS_SOFTWARE=1
cd "$WORK"
"$IMAGE" --appimage-extract-and-run > "$LOG" 2>&1 &
pid=$!
ready=0
for _ in {1..150}; do
  if grep -Fq MSTEAMS_UI_READY "$LOG"; then ready=1; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if [[ "$ready" != 1 ]]; then
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' "$LOG"
  echo "ERROR: the packaged link fixture did not become ready" >&2
  exit 1
fi
window="$(xdotool search --onlyvisible --name 'Microsoft Teams' | head -1)"
xdotool windowfocus --sync "$window"
# Real X11 events carry isTrusted/user-gesture state. JavaScript .click() does not.
xdotool mousemove --window "$window" 40 40 click 1
xdotool mousemove --window "$window" 40 120 click 1
xdotool mousemove --window "$window" 40 200 click 2
complete=0
for _ in {1..100}; do
  if [[ -f "$MSTEAMS_CI_LINK_LOG" ]] && [[ "$(wc -l < "$MSTEAMS_CI_LINK_LOG")" -ge 3 ]]; then complete=1; break; fi
  sleep 0.1
done
if [[ "$complete" != 1 ]]; then
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' "$LOG"
  echo "ERROR: one or more real clicks did not reach the host browser launcher" >&2
  exit 1
fi
xdotool mousemove --window "$window" 40 280 click 1
auth=0
for _ in {1..50}; do
  if grep -Fq MSTEAMS_AUTH_POPUP_CREATED "$LOG" && [[ "$(xdotool search --onlyvisible --name 'Microsoft Teams' | wc -l)" -ge 2 ]]; then auth=1; break; fi
  sleep 0.1
done
if [[ "$auth" != 1 ]]; then
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' "$LOG"
  echo "ERROR: authentication did not create a visible in-app popup" >&2
  exit 1
fi
python3 - <<'PY'
import os
from pathlib import Path
actual = Path(os.environ['MSTEAMS_CI_LINK_LOG']).read_text().splitlines()
expected = [
    'https://example.invalid/chat-link?x=1&y=2',
    'https://learn.microsoft.com/en-us/msteams-link-check',
    'https://example.invalid/middle-click',
]
assert sorted(actual) == sorted(expected), f'Missing, duplicated or hijacked auth links: {actual}'
print('PASS: target=_blank, same-frame Microsoft and middle-click links reached the host opener exactly once; authentication created a visible in-app popup')
PY
