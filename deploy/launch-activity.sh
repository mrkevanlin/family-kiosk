#!/usr/bin/env bash
# Launch a kid activity Chromium profile.
# Usage: launch-activity.sh homework|mblock|web
set -euo pipefail

ACTIVITY="${1:-}"
CONFIG="${FAMILY_KIOSK_CONFIG:-/etc/family-kiosk/config.yaml}"
CHROMIUM="$(command -v chromium-browser || command -v chromium || true)"
PROFILE_ROOT="${HOME}/.config/family-kiosk-chromium"
mkdir -p "$PROFILE_ROOT"

if [[ -z "$CHROMIUM" ]]; then
  echo "Chromium not found" >&2
  exit 1
fi

# Parse a few values from YAML without requiring PyYAML in the kid session.
mblock_url="$(python3 - <<'PY' "$CONFIG"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
print(cfg.get("mblock_url", "https://ide.mblock.cc"))
PY
)"

homework_patterns="$(python3 - <<'PY' "$CONFIG"
import sys, yaml, json
cfg = yaml.safe_load(open(sys.argv[1]))
print(json.dumps(cfg.get("homework_url_allowlist", [])))
PY
)"

case "$ACTIVITY" in
  homework)
    # URL-block via Chromium extension-less allowlist is limited; we rely on the
    # allowlist proxy for enforcement and open the first homework URL.
    first="$(python3 - <<'PY' "$CONFIG"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
urls = cfg.get("homework_url_allowlist") or ["https://classroom.google.com/"]
print(urls[0].replace("/*", "/"))
PY
)"
    exec "$CHROMIUM" \
      --new-window \
      --app="$first" \
      --user-data-dir="$PROFILE_ROOT/homework" \
      --proxy-server="http://127.0.0.1:8888" \
      "$first"
    ;;
  mblock)
    exec "$CHROMIUM" \
      --new-window \
      --app="$mblock_url" \
      --user-data-dir="$PROFILE_ROOT/mblock" \
      --proxy-server="http://127.0.0.1:8888" \
      "$mblock_url"
    ;;
  web)
    # Unrestricted browsing only while nftables allows the kid UID.
    exec "$CHROMIUM" \
      --new-window \
      --user-data-dir="$PROFILE_ROOT/web" \
      --no-proxy-server \
      "https://www.wikipedia.org"
    ;;
  *)
    echo "Usage: $0 homework|mblock|web" >&2
    exit 2
    ;;
esac
