#!/usr/bin/env bash
# Diagnose / repair child kiosk session on Ubuntu after install.
# Run as parent with sudo: sudo bash deploy/fix-kiosk.sh [child_username]
#
# You do NOT need the login-screen gear icon. This script forces the child
# account's default session to GNOME Kiosk. The gear only appears when GDM
# sees multiple sessions; if kiosk packages were missing, Ubuntu was the only
# option and the gear stays hidden.
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
KID_UID="$(id -u "$KID_USER")"
echo "Child user: $KID_USER (uid $KID_UID)"
echo "Home:       $KID_HOME"
echo

echo "==> Ensure GNOME Kiosk packages are installed"
apt-get update -qq
apt-get install -y gnome-kiosk gnome-kiosk-script-session curl || true
dpkg -l gnome-kiosk gnome-kiosk-script-session 2>/dev/null | awk '/^ii/ {print}' || true

echo
echo "==> Available sessions"
echo "Wayland:"
ls -1 /usr/share/wayland-sessions/*.desktop 2>/dev/null || echo "  (none)"
echo "X11:"
ls -1 /usr/share/xsessions/*.desktop 2>/dev/null || echo "  (none)"

pick_session() {
  local candidate
  for candidate in \
    gnome-kiosk-script-wayland \
    gnome-kiosk-script \
    org.gnome.Kiosk.Script.Session \
    org.gnome.Kiosk.Script
  do
    if [[ -f "/usr/share/wayland-sessions/${candidate}.desktop" ]] \
      || [[ -f "/usr/share/xsessions/${candidate}.desktop" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  # Fuzzy match
  candidate="$(ls /usr/share/wayland-sessions/*[Kk]iosk*[Ss]cript*.desktop 2>/dev/null | head -1 || true)"
  if [[ -n "$candidate" ]]; then
    basename "$candidate" .desktop
    return 0
  fi
  candidate="$(ls /usr/share/xsessions/*[Kk]iosk*[Ss]cript*.desktop 2>/dev/null | head -1 || true)"
  if [[ -n "$candidate" ]]; then
    basename "$candidate" .desktop
    return 0
  fi
  return 1
}

if ! SESSION="$(pick_session)"; then
  echo
  echo "ERROR: No GNOME Kiosk session desktop file found after package install." >&2
  echo "Without that session, GDM only offers Ubuntu — so there is no gear icon," >&2
  echo "and the child account keeps opening a normal desktop." >&2
  echo
  echo "Try manually:" >&2
  echo "  sudo apt install gnome-kiosk gnome-kiosk-script-session" >&2
  echo "  ls /usr/share/wayland-sessions /usr/share/xsessions" >&2
  exit 1
fi
echo
echo "Using session id: $SESSION"

echo
echo "==> familyd"
systemctl is-active familyd || true
curl -sf http://127.0.0.1:8787/healthz && echo || echo "familyd healthz FAILED — run: sudo systemctl restart familyd"

echo
echo "==> Chromium"
command -v chromium-browser || true
command -v chromium || true
ls -l /snap/bin/chromium 2>/dev/null || true

echo
echo "==> Reinstalling kiosk script"
SCRIPT_SRC="$INSTALL_DIR/deploy/gnome-kiosk-script"
if [[ ! -f "$SCRIPT_SRC" ]]; then
  SCRIPT_SRC="$ROOT/deploy/gnome-kiosk-script"
fi
install -d -o "$KID_USER" -g "$KID_USER" "$KID_HOME/.local/bin" "$KID_HOME/.local/state/family-kiosk"
install -m 755 -o "$KID_USER" -g "$KID_USER" "$SCRIPT_SRC" "$KID_HOME/.local/bin/gnome-kiosk-script"
# Default gnome-kiosk package may ship a stub that opens a text editor — overwrite it.
ls -l "$KID_HOME/.local/bin/gnome-kiosk-script"
head -n 5 "$KID_HOME/.local/bin/gnome-kiosk-script"

echo
echo "==> Forcing default session (no gear needed)"
AS_FILE="/var/lib/AccountsService/users/$KID_USER"
mkdir -p /var/lib/AccountsService/users
cat >"$AS_FILE" <<EOF
[User]
Language=
Session=$SESSION
XSession=$SESSION
SystemAccount=false
EOF
chmod 644 "$AS_FILE"

cat >"$KID_HOME/.dmrc" <<EOF
[Desktop]
Session=$SESSION
EOF
chown "$KID_USER:$KID_USER" "$KID_HOME/.dmrc"

# Tell accounts-daemon via D-Bus when possible (survives better than file-only edits).
if command -v busctl >/dev/null; then
  USER_PATH="$(busctl call org.freedesktop.Accounts /org/freedesktop/Accounts \
    org.freedesktop.Accounts FindUserByName s "$KID_USER" 2>/dev/null | awk '{print $2}' | tr -d '"')" || true
  if [[ -n "${USER_PATH:-}" ]]; then
    busctl call org.freedesktop.Accounts "$USER_PATH" \
      org.freedesktop.Accounts.User SetXSession s "$SESSION" 2>/dev/null \
      && echo "accounts-daemon SetXSession OK" \
      || echo "accounts-daemon SetXSession skipped"
  fi
fi

systemctl restart accounts-daemon 2>/dev/null || true

echo "AccountsService file:"
cat "$AS_FILE"

echo
echo "==> Recent kiosk log (if any)"
LOG="$KID_HOME/.local/state/family-kiosk/kiosk.log"
if [[ -f "$LOG" ]]; then
  tail -n 40 "$LOG"
else
  echo "(no log yet — child has not started the kiosk script)"
fi

echo
echo "============================================================"
echo "The gear icon is optional. GDM hides it when only one session"
echo "is available — that is normal on a stock Ubuntu install."
echo
echo "Next steps:"
echo "  1. Reboot (recommended):  sudo reboot"
echo "  2. At the login screen, select $KID_USER and sign in."
echo "     Do NOT look for a gear — the default session is now: $SESSION"
echo "  3. You should get a full-screen Family Computer picker."
echo "  4. If you still get a normal desktop, send output of:"
echo "       ls /usr/share/wayland-sessions /usr/share/xsessions"
echo "       cat /var/lib/AccountsService/users/$KID_USER"
echo "       sudo tail -n 80 $LOG"
echo "============================================================"
