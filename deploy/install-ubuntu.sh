#!/usr/bin/env bash
# Install Family Kiosk on Ubuntu 24.04 (run as a sudo-capable parent user).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/family-kiosk}"
KID_USER="${KID_USER:-kid}"
PARENT_USER="${PARENT_USER:-$USER}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo…"
  exec sudo INSTALL_DIR="$INSTALL_DIR" KID_USER="$KID_USER" PARENT_USER="$PARENT_USER" bash "$0" "$@"
fi

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

echo "==> Creating kid user (if missing)"
if ! id "$KID_USER" &>/dev/null; then
  adduser --disabled-password --gecos "Kid" "$KID_USER"
  echo "Set a password for $KID_USER:"
  passwd "$KID_USER"
fi

groupadd -f familykiosk
usermod -aG familykiosk "$KID_USER" || true
usermod -aG familykiosk "$PARENT_USER" || true

echo "==> Installing application to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" /etc/family-kiosk /var/lib/family-kiosk
rsync -a --delete \
  --exclude '.venv' --exclude 'data' --exclude '.git' --exclude '__pycache__' \
  "$ROOT/" "$INSTALL_DIR/"

python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

if [[ ! -f /etc/family-kiosk/config.yaml ]]; then
  cp "$INSTALL_DIR/config/config.example.yaml" /etc/family-kiosk/config.yaml
  # Production defaults
  sed -i 's/dry_run_network: true/dry_run_network: false/' /etc/family-kiosk/config.yaml
  sed -i 's|data_dir: "data"|data_dir: "/var/lib/family-kiosk"|' /etc/family-kiosk/config.yaml
  sed -i "s/kid_username: kid/kid_username: $KID_USER/" /etc/family-kiosk/config.yaml
  echo "IMPORTANT: edit /etc/family-kiosk/config.yaml and change parent_pin"
fi

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
install -d -o "$KID_USER" -g "$KID_USER" "/home/$KID_USER/.local/bin"
install -m 755 -o "$KID_USER" -g "$KID_USER" \
  "$INSTALL_DIR/deploy/gnome-kiosk-script" \
  "/home/$KID_USER/.local/bin/gnome-kiosk-script"

# Force GNOME Kiosk session for the kid account
mkdir -p /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/$KID_USER" <<EOF
[User]
Session=gnome-kiosk-script-wayland
SystemAccount=false
EOF

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
echo "  2. Log in as $KID_USER — kiosk picker should open"
echo "  3. On your iPhone (home Wi-Fi): http://family-pc.local:8787/parent"
echo "  4. Parent account ($PARENT_USER) keeps a normal Ubuntu desktop"
echo "  5. Verify chrome://policy shows ForceGoogleSafeSearch (see deploy/GOOGLE-SAFE.md)"
echo "  6. Turn on Family Link / Workspace SafeSearch for his Google account too"
