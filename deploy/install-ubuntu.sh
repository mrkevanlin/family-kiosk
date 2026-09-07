#!/usr/bin/env bash
# Install Family Kiosk on Ubuntu 24.04 (run as a sudo-capable parent user).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/family-kiosk}"
KID_USER="${KID_USER:-}"
PARENT_USER="${PARENT_USER:-${SUDO_USER:-$USER}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo…"
  exec sudo INSTALL_DIR="$INSTALL_DIR" KID_USER="$KID_USER" PARENT_USER="$PARENT_USER" bash "$0" "$@"
fi

# If invoked as `sudo bash …`, prefer the real login user as parent.
if [[ "$PARENT_USER" == "root" && -n "${SUDO_USER:-}" ]]; then
  PARENT_USER="$SUDO_USER"
fi

list_login_users() {
  getent passwd | awk -F: '
    $3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)/ { print $1 }
  '
}

choose_kid_user() {
  local users=()
  local user
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    # Parent account should stay a normal desktop — do not kiosk it.
    if [[ "$user" == "$PARENT_USER" ]]; then
      continue
    fi
    users+=("$user")
  done < <(list_login_users)

  if [[ ${#users[@]} -eq 0 ]]; then
    echo "No other login users found besides '$PARENT_USER'." >&2
    echo "Create your child's Ubuntu account first (Settings → Users), then re-run." >&2
    exit 1
  fi

  echo
  echo "Which existing account should be the child (kiosk) account?"
  echo "This account will boot into the Family Kiosk picker instead of a normal desktop."
  local i=1
  for user in "${users[@]}"; do
    echo "  $i) $user"
    i=$((i + 1))
  done
  echo

  local choice
  while true; do
    read -r -p "Enter number (1-${#users[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#users[@]} )); then
      KID_USER="${users[$((choice - 1))]}"
      break
    fi
    echo "Invalid choice. Pick a number between 1 and ${#users[@]}."
  done
}

echo "==> Selecting child account"
if [[ -n "$KID_USER" ]]; then
  if ! id "$KID_USER" &>/dev/null; then
    echo "KID_USER='$KID_USER' does not exist. Unset it to choose from a list." >&2
    exit 1
  fi
  if [[ "$KID_USER" == "$PARENT_USER" ]]; then
    echo "Child account cannot be the same as the parent account ('$PARENT_USER')." >&2
    exit 1
  fi
  if ! list_login_users | grep -qx "$KID_USER"; then
    echo "KID_USER='$KID_USER' is not a normal login account (UID >= 1000)." >&2
    exit 1
  fi
  echo "Using child account from environment: $KID_USER"
else
  choose_kid_user
fi

KID_HOME="$(getent passwd "$KID_USER" | cut -d: -f6)"
if [[ -z "$KID_HOME" || ! -d "$KID_HOME" ]]; then
  echo "Home directory for '$KID_USER' not found." >&2
  exit 1
fi

echo "Child (kiosk) account: $KID_USER ($KID_HOME)"
echo "Parent account:        $PARENT_USER"

echo "==> Installing system packages"
apt-get update
apt-get install -y \
  python3 python3-venv python3-pip \
  chromium-browser chromium-chromedriver \
  gnome-kiosk gnome-kiosk-script-session \
  nftables curl avahi-daemon \
  || apt-get install -y python3 python3-venv chromium gnome-kiosk nftables curl avahi-daemon

# Ubuntu 24.04 may ship chromium as a snap transitional package; prefer chromium if present.
CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "WARNING: Chromium not found. Install chromium-browser before using the kiosk."
fi

groupadd -f familykiosk
usermod -aG familykiosk "$KID_USER" || true
usermod -aG familykiosk "$PARENT_USER" || true

echo "==> Installing application to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" /etc/family-kiosk /var/lib/family-kiosk
rsync -a --delete \
  --exclude '.venv' --exclude 'data' --exclude '.git' --exclude '__pycache__' \
  "$ROOT/" "$INSTALL_DIR/"

# Ubuntu 24.04 ships Python 3.12. Avoid bleeding-edge interpreters without wheels.
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if ! python3 -c 'import sys; raise SystemExit(0 if (3,11) <= sys.version_info[:2] <= (3,13) else 1)'; then
  echo "WARNING: python3 is $PY_VER; Family Kiosk expects Python 3.11–3.13." >&2
  echo "On Ubuntu 24.04 this is normally 3.12. If pip fails on pydantic-core, install python3.12 and recreate the venv." >&2
fi

python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

if [[ ! -f /etc/family-kiosk/config.yaml ]]; then
  cp "$INSTALL_DIR/config/config.example.yaml" /etc/family-kiosk/config.yaml
  # Production defaults
  sed -i 's/dry_run_network: true/dry_run_network: false/' /etc/family-kiosk/config.yaml
  sed -i 's|data_dir: "data"|data_dir: "/var/lib/family-kiosk"|' /etc/family-kiosk/config.yaml
  echo "IMPORTANT: edit /etc/family-kiosk/config.yaml and change parent_pin"
fi
# Always point config at the chosen child account.
sed -i "s/^kid_username:.*/kid_username: $KID_USER/" /etc/family-kiosk/config.yaml

chown -R root:root "$INSTALL_DIR"
chmod 750 /etc/family-kiosk
chmod 640 /etc/family-kiosk/config.yaml
mkdir -p /var/lib/family-kiosk
chown -R root:familykiosk /var/lib/family-kiosk
chmod 2775 /var/lib/family-kiosk

echo "==> Installing systemd unit"
cp "$INSTALL_DIR/deploy/familyd.service" /etc/systemd/system/familyd.service
systemctl daemon-reload
systemctl enable --now familyd.service

echo "==> Installing Chromium SafeSearch / SafeSites policies"
bash "$INSTALL_DIR/deploy/install-chromium-policies.sh" || true

echo "==> Installing kiosk launcher for $KID_USER"
install -d -o "$KID_USER" -g "$KID_USER" \
  "$KID_HOME/.local/bin" \
  "$KID_HOME/.local/state/family-kiosk"
install -m 755 -o "$KID_USER" -g "$KID_USER" \
  "$INSTALL_DIR/deploy/gnome-kiosk-script" \
  "$KID_HOME/.local/bin/gnome-kiosk-script"

# Detect the installed kiosk session id (package names vary slightly).
KIOSK_SESSION="gnome-kiosk-script-wayland"
if [[ ! -f /usr/share/wayland-sessions/gnome-kiosk-script-wayland.desktop ]]; then
  if [[ -f /usr/share/wayland-sessions/gnome-kiosk-script.desktop ]]; then
    KIOSK_SESSION="gnome-kiosk-script"
  elif ls /usr/share/wayland-sessions/*kiosk*script*wayland*.desktop >/dev/null 2>&1; then
    KIOSK_SESSION="$(basename "$(ls /usr/share/wayland-sessions/*kiosk*script*wayland*.desktop | head -1)" .desktop)"
  elif ls /usr/share/wayland-sessions/*kiosk*script*.desktop >/dev/null 2>&1; then
    KIOSK_SESSION="$(basename "$(ls /usr/share/wayland-sessions/*kiosk*script*.desktop | head -1)" .desktop)"
  else
    echo "WARNING: No GNOME Kiosk session desktop file found."
    echo "         Install gnome-kiosk-script-session, then run: sudo bash deploy/fix-kiosk.sh $KID_USER"
  fi
fi
echo "Kiosk session: $KIOSK_SESSION"

# Force GNOME Kiosk session for the child account (preserve other AccountsService keys).
AS_FILE="/var/lib/AccountsService/users/$KID_USER"
mkdir -p /var/lib/AccountsService/users
if [[ -f "$AS_FILE" ]] && grep -q '^\[User\]' "$AS_FILE"; then
  if grep -q '^Session=' "$AS_FILE"; then
    sed -i "s/^Session=.*/Session=$KIOSK_SESSION/" "$AS_FILE"
  else
    printf '\nSession=%s\n' "$KIOSK_SESSION" >>"$AS_FILE"
  fi
  sed -i '/^XSession=/d' "$AS_FILE" || true
  if grep -q '^SystemAccount=' "$AS_FILE"; then
    sed -i 's/^SystemAccount=.*/SystemAccount=false/' "$AS_FILE"
  else
    printf 'SystemAccount=false\n' >>"$AS_FILE"
  fi
else
  cat >"$AS_FILE" <<EOF
[User]
Session=$KIOSK_SESSION
SystemAccount=false
EOF
fi

cat >"$KID_HOME/.dmrc" <<EOF
[Desktop]
Session=$KIOSK_SESSION
EOF
chown "$KID_USER:$KID_USER" "$KID_HOME/.dmrc"
systemctl restart accounts-daemon 2>/dev/null || true

# Hostname for phone bookmark (family-pc.local)
hostnamectl set-hostname family-pc || true

echo "==> Optional: mBlock mLink"
echo "    Download mLink .deb from https://mblock.cc/pages/downloads"
echo "    sudo dpkg -i mLink-*-amd64.deb && sudo mblock-mlink start"
echo "    If robots are not detected:"
echo "      sudo mv /usr/lib/udev/rules.d/85-brltty.rules /usr/lib/udev/rules.d/85-brltty.rules.disabled"
echo "      sudo udevadm control --reload-rules"

echo
echo "Done."
echo "  1. Edit /etc/family-kiosk/config.yaml (PIN, hours, homework allowlist)"
echo "  2. Log out completely (or reboot), then sign in as $KID_USER"
echo "     (No gear icon needed — their default session is forced to kiosk.)"
echo "  3. If a normal desktop still appears: sudo bash $INSTALL_DIR/deploy/fix-kiosk.sh $KID_USER && sudo reboot"
echo "  4. On your iPhone (home Wi-Fi): http://family-pc.local:8787/parent"
echo "  5. Parent account ($PARENT_USER) keeps a normal Ubuntu desktop"
echo "  6. Verify chrome://policy shows ForceGoogleSafeSearch (see deploy/GOOGLE-SAFE.md)"
echo "  7. Turn on Family Link / Workspace SafeSearch for his Google account too"
