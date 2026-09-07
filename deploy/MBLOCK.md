# mBlock on Ubuntu (Family Kiosk)

Makeblock does **not** provide a current native Linux desktop app for mBlock 5.
Use the **web IDE** plus the **mLink** USB bridge.

## Install mLink

1. Open https://mblock.cc/pages/downloads
2. Download **mLink** for Linux (`.deb`)
3. Install and start:

```bash
sudo dpkg -i mLink-*-amd64.deb
sudo mblock-mlink start
# optional: enable at boot
sudo systemctl enable --now mblock-mlink 2>/dev/null || true
```

4. If a robot / serial device is not detected (common on Ubuntu):

```bash
sudo mv /usr/lib/udev/rules.d/85-brltty.rules \
        /usr/lib/udev/rules.d/85-brltty.rules.disabled
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Then unplug/replug the robot or USB dongle.

## In the kiosk

The **mBlock** tile opens https://ide.mblock.cc through the allowlist proxy, so it works even when general internet is off.

If the IDE needs extra CDN hosts, add them under `always_allow_domains` in `/etc/family-kiosk/config.yaml` and restart:

```bash
sudo systemctl restart familyd
```
