#!/usr/bin/env bash
# Install Chromium managed policies that force Google SafeSearch, YouTube Restricted
# Mode (strict), and SafeSites adult filtering for the kid kiosk browsers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_SRC="$ROOT/deploy/chromium-policies/kid-safe.json"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo…"
  exec sudo bash "$0" "$@"
fi

if [[ ! -f "$POLICY_SRC" ]]; then
  echo "Missing policy file: $POLICY_SRC" >&2
  exit 1
fi

# Cover deb Chromium, Chrome, and snap Chromium policy roots.
TARGETS=(
  /etc/chromium/policies/managed
  /etc/chromium-browser/policies/managed
  /etc/opt/chrome/policies/managed
  /var/snap/chromium/current/policies/managed
)

installed=0
for dir in "${TARGETS[@]}"; do
  parent="$(dirname "$dir")"
  # Only create under existing product trees, except the common /etc chromium paths.
  case "$dir" in
    /etc/chromium/*|/etc/chromium-browser/*|/etc/opt/chrome/*)
      mkdir -p "$dir"
      ;;
    /var/snap/chromium/*)
      if [[ -d /var/snap/chromium ]]; then
        mkdir -p "$dir"
      else
        continue
      fi
      ;;
  esac
  if [[ -d "$dir" ]]; then
    install -m 644 -o root -g root "$POLICY_SRC" "$dir/kid-safe.json"
    echo "Installed $dir/kid-safe.json"
    installed=$((installed + 1))
  fi
done

if [[ "$installed" -eq 0 ]]; then
  echo "WARNING: no Chromium policy directories were available." >&2
  echo "Install Chromium first, then re-run this script." >&2
  exit 1
fi

echo
echo "Policies installed. On the kid machine, open chrome://policy in Chromium"
echo "and confirm ForceGoogleSafeSearch / SafeSitesFilterBehavior are set."
echo
echo "Also turn on SafeSearch in Google Family Link (or Workspace admin) so the"
echo "lock follows his Google account, not only this computer."
