#!/usr/bin/env bash
# Launch a kid activity Chromium profile.
# Usage: launch-activity.sh homework|mblock|apple_music|typesy|web
set -euo pipefail

ACTIVITY="${1:-}"
CONFIG="${FAMILY_KIOSK_CONFIG:-/etc/family-kiosk/config.yaml}"
CHROMIUM="$(command -v chromium-browser || command -v chromium || true)"
PROFILE_ROOT="${HOME}/.config/family-kiosk-chromium"
EXTENSION_SRC="$(cd "$(dirname "$0")" && pwd)/activity-header"
EXTENSION_DIR="${HOME}/.local/share/family-kiosk/activity-header"
mkdir -p "$PROFILE_ROOT"

if [[ -z "$CHROMIUM" ]]; then
  echo "Chromium not found" >&2
  exit 1
fi

if [[ ! -f "$EXTENSION_SRC/manifest.json" ]]; then
  echo "Activity header extension not found: $EXTENSION_SRC" >&2
  exit 1
fi
mkdir -p "$EXTENSION_DIR"
cp -a "$EXTENSION_SRC/." "$EXTENSION_DIR/"

# Shared Chromium flags: SafeSearch policies come from managed JSON installed
# by deploy/install-chromium-policies.sh (see chrome://policy).
COMMON_FLAGS=(
  --noerrdialogs
  --disable-infobars
  --no-first-run
  --disable-session-crashed-bubble
  --disable-translate
  --autoplay-policy=no-user-gesture-required
  "--proxy-bypass-list=127.0.0.1,localhost,<local>"
  --disable-extensions-except="$EXTENSION_DIR"
  --load-extension="$EXTENSION_DIR"
)

read_cfg() {
  local key="$1"
  local default="$2"
  python3 - "$CONFIG" "$key" "$default" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
print(cfg.get(sys.argv[2], sys.argv[3]))
PY
}

case "$ACTIVITY" in
  homework)
    start="$(read_cfg homework_start_url 'https://www.google.com/?safe=active&ssui=on')"
    exec "$CHROMIUM" \
      "${COMMON_FLAGS[@]}" \
      --new-window \
      --user-data-dir="$PROFILE_ROOT/homework" \
      --proxy-server="http://127.0.0.1:8888" \
      "$start"
    ;;
  mblock)
    mblock_url="$(read_cfg mblock_url 'https://ide.mblock.cc')"
    exec "$CHROMIUM" \
      "${COMMON_FLAGS[@]}" \
      --new-window \
      --app="$mblock_url" \
      --user-data-dir="$PROFILE_ROOT/mblock" \
      --proxy-server="http://127.0.0.1:8888" \
      "$mblock_url"
    ;;
  apple_music)
    music_url="$(read_cfg apple_music_url 'https://music.apple.com/us/browse')"
    exec "$CHROMIUM" \
      "${COMMON_FLAGS[@]}" \
      --new-window \
      --app="$music_url" \
      --user-data-dir="$PROFILE_ROOT/apple_music" \
      --proxy-server="http://127.0.0.1:8888" \
      "$music_url"
    ;;
  typesy)
    typesy_url="$(read_cfg typesy_url 'https://www.typesy.com/type/')"
    exec "$CHROMIUM" \
      "${COMMON_FLAGS[@]}" \
      --new-window \
      --app="$typesy_url" \
      --user-data-dir="$PROFILE_ROOT/typesy" \
      --proxy-server="http://127.0.0.1:8888" \
      "$typesy_url"
    ;;
  web)
    # General browsing while an approved session is active.
    # SafeSearch / SafeSites policies still apply via managed Chromium config.
    exec "$CHROMIUM" \
      "${COMMON_FLAGS[@]}" \
      --new-window \
      --user-data-dir="$PROFILE_ROOT/web" \
      --no-proxy-server \
      "https://www.google.com/?safe=active&ssui=on"
    ;;
  *)
    echo "Usage: $0 homework|mblock|apple_music|typesy|web" >&2
    exit 2
    ;;
esac
