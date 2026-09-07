#!/usr/bin/env bash
# Diagnose / repair child kiosk session on Ubuntu after install.
# Run as parent with sudo: sudo bash deploy/fix-kiosk.sh [child_username]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/family-kiosk}"

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo INSTALL_DIR="$INSTALL_DIR" bash "$0" "$@"
fi

KID_USER="${1:-}"
if [[ -z "$KID_USER" && -f /etc/family-kiosk/config.yaml ]]; then
  KID_USER="$(awk -F': *' '/^kid_username:/ {print $2; exit}' /etc/family-kiosk/config.yaml | tr -d '"')"
fi
if [[ -z "$KID_USER" ]]; then
  echo "Usage: $0 <child_username>" >&2
  exit 1
fi
if ! id "$KID_USER" &>/dev/null; then
  echo "User '$KID_USER' not found" >&2
  exit 1
fi

KID_HOME="$(getent passwd "$KID_USER" | cut -d: -f6)"
echo "Child user: $KID_USER"
echo "Home:       $KID_HOME"
echo

echo "==> familyd"
systemctl is-active familyd || true
curl -sf http://127.0.0.1:8787/healthz && echo || echo "familyd healthz FAILED"

echo
echo "==> Chromium"
command -v chromium-browser || true
command -v chromium || true
ls -l /snap/bin/chromium 2>/dev/null || true

echo
echo "==> GNOME Kiosk packages / sessions"
dpkg -l gnome-kiosk gnome-kiosk-script-session 2>/dev/null | awk '/^ii/ {print}' || true
ls /usr/share/wayland-sessions/*[Kk]iosk* 2>/dev/null || echo "No wayland kiosk session desktops found"
ls /usr/share/xsessions/*[Kk]iosk* 2>/dev/null || echo "No xsession kiosk desktops found"

SESSION="gnome-kiosk-script-wayland"
if [[ ! -f /usr/share/wayland-sessions/gnome-kiosk-script-wayland.desktop ]] \
  && [[ ! -f /usr/share/wayland-sessions/gnome-kiosk-script.desktop ]]; then
  if [[ -f /usr/share/wayland-sessions/gnome-kiosk-script.desktop ]]; then
    SESSION="gnome-kiosk-script"
  elif ls /usr/share/wayland-sessions/*kiosk*script*wayland*.desktop >/dev/null 2>&1; then
    SESSION="$(basename "$(ls /usr/share/wayland-sessions/*kiosk*script*wayland*.desktop | head -1)" .desktop)"
  elif ls /usr/share/wayland-sessions/*kiosk*script*.desktop >/dev/null 2>&1; then
    SESSION="$(basename "$(ls /usr/share/wayland-sessions/*kiosk*script*.desktop | head -1)" .desktop)"
  fi
fi
echo "Using session id: $SESSION"

echo
echo "==> Reinstalling kiosk script"
SCRIPT_SRC="$INSTALL_DIR/deploy/gnome-kiosk-script"
if [[ ! -f "$SCRIPT_SRC" ]]; then
  SCRIPT_SRC="$ROOT/deploy/gnome-kiosk-script"
fi
install -d -o "$KID_USER" -g "$KID_USER" "$KID_HOME/.local/bin" "$KID_HOME/.local/state/family-kiosk"
install -m 755 -o "$KID_USER" -g "$KID_USER" "$SCRIPT_SRC" "$KID_HOME/.local/bin/gnome-kiosk-script"
ls -l "$KID_HOME/.local/bin/gnome-kiosk-script"

echo
echo "==> Setting AccountsService + .dmrc session"
AS_FILE="/var/lib/AccountsService/users/$KID_USER"
mkdir -p /var/lib/AccountsService/users
if [[ -f "$AS_FILE" ]]; then
  # Update Session= in place when possible; otherwise rewrite minimally.
  if grep -q '^Session=' "$AS_FILE"; then
    sed -i "s/^Session=.*/Session=$SESSION/" "$AS_FILE"
  else
    printf '\nSession=%s\n' "$SESSION" >>"$AS_FILE"
  fi
  if grep -q '^SystemAccount=' "$AS_FILE"; then
    sed -i 's/^SystemAccount=.*/SystemAccount=false/' "$AS_FILE"
  else
    printf 'SystemAccount=false\n' >>"$AS_FILE"
  fi
else
  cat >"$AS_FILE" <<EOF
[User]
Session=$SESSION
SystemAccount=false
EOF
fi
# Remove stale XSession overrides that can force Ubuntu desktop.
sed -i '/^XSession=/d' "$AS_FILE" || true

cat >"$KID_HOME/.dmrc" <<EOF
[Desktop]
Session=$SESSION
EOF
chown "$KID_USER:$KID_USER" "$KID_HOME/.dmrc"

echo "AccountsService now:"
cat "$AS_FILE"
systemctl restart accounts-daemon 2>/dev/null || true

echo
echo "==> Recent kiosk log (if any)"
LOG="$KID_HOME/.local/state/family-kiosk/kiosk.log"
if [[ -f "$LOG" ]]; then
  tail -n 40 "$LOG"
else
  echo "(no log yet — child has not started the kiosk script)"
fi

echo
echo "Next:"
echo "  1. Fully log out of the child account (or reboot)."
echo "  2. On the login screen, click the child user, then the gear icon (bottom-right)."
echo "  3. Choose 'GNOME Kiosk Script' / Wayland, then sign in."
echo "  4. If it still fails, as parent run: sudo tail -n 80 $LOG"
