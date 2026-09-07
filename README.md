# Family Kiosk

A simple Ubuntu kiosk for a family mini PC (GMKtec G10 and similar). Your child gets a full-screen activity picker — not a normal desktop — with computer hours and parent-approved internet sessions.

## What it does

- **Kid login** opens a GNOME Kiosk session with one screen: Homework, mBlock, Ask for internet, and Web (only while internet is approved).
- **Computer hours** (default Eastern Time): weekdays 4–8 PM, weekends 9 AM–8 PM. Outside those hours the picker shows a closed state.
- **Internet** is off by default. Homework and mBlock domains stay reachable. Everything else needs a timed approval (15 / 30 / 60 minutes).
- **Parent review** on your iPhone (home Wi‑Fi): open `http://family-pc.local:8787/parent`, enter your PIN, approve or deny. Push notifications can come later.

## Quick start (Mac / browser preview)

```bash
cd family-kiosk
# Prefer Python 3.11–3.13 (Homebrew: python3.13). System 3.14 may lack wheels.
python3.13 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp config/config.example.yaml config/config.yaml   # if needed
python -m familyd
```

Then open:

- Kid picker: http://127.0.0.1:8787/
- Parent dashboard: http://127.0.0.1:8787/parent  
  Default PIN: `1234` (change in `config/config.yaml`)

```bash
pytest -q
```

## Ubuntu 24.04 on the G10

1. Install Ubuntu Desktop (wipe Windows). Ryzen 5 3500U / Vega 8 works well. If 2.5GbE is flaky (Realtek RTL8125), use Wi‑Fi.
2. Create your **parent** account during install (full desktop + sudo).
3. Copy this repo onto the machine, then:

```bash
sudo bash deploy/install-ubuntu.sh
sudo nano /etc/family-kiosk/config.yaml   # change parent_pin, hours, homework sites
sudo systemctl restart familyd
```

4. Log out and log in as the **kid** user — the kiosk picker should fill the screen.
5. On your iPhone (same Wi‑Fi), bookmark **http://family-pc.local:8787/parent**.

### mBlock (Linux)

Makeblock does not ship a Linux desktop app. Use the web IDE plus mLink:

1. Download the Linux `.deb` from [mBlock downloads](https://mblock.cc/pages/downloads) (mLink section).
2. `sudo dpkg -i mLink-*-amd64.deb && sudo mblock-mlink start`
3. If a robot is not detected:  
   `sudo mv /usr/lib/udev/rules.d/85-brltty.rules /usr/lib/udev/rules.d/85-brltty.rules.disabled`  
   then `sudo udevadm control --reload-rules`

Kid tile **mBlock** opens https://ide.mblock.cc through the allowlist proxy.

## Layout

| Path | Role |
|------|------|
| `familyd/` | FastAPI daemon: hours, requests, sessions, PIN, nftables hook, allowlist proxy |
| `templates/` | Kid picker + parent dashboard HTML |
| `static/` | CSS / JS |
| `config/` | YAML config (hours, allowlists, PIN) |
| `deploy/` | systemd unit, GNOME kiosk script, Ubuntu installer |

## Parent PIN exit

On the kid screen, **Parent** asks for the PIN and writes an exit flag. The kiosk wrapper ends the kid session so you can log into the parent desktop.

See also [deploy/MBLOCK.md](deploy/MBLOCK.md) for robot USB setup.

## Network model

- `familyd` runs as root (systemd) and manages an `inet family_kiosk` nftables table.
- When internet is **off**, the kid UID cannot make general outbound connections (loopback, DNS, and port 8787 stay open).
- An allowlist HTTP proxy on `127.0.0.1:8888` lets Homework / mBlock domains through while general web stays blocked.
- When you approve a session, nftables restrictions are cleared until the timer ends.

## Config highlights

Edit `/etc/family-kiosk/config.yaml` (or `config/config.yaml` in dev):

- `parent_pin` — dashboard + kiosk exit
- `hours` — per-day start/end
- `homework_url_allowlist` — school sites
- `always_allow_domains` — proxy allowlist (includes mBlock hosts)
- `session_durations` — `[15, 30, 60]`
- `dry_run_network: true` on Mac; `false` on the G10

## Security notes

This is a home appliance control layer, not a hardened enterprise lockdown. A determined user with physical access and time can still find ways around kiosk Chromium. Keep the parent account password strong, do not give the kid sudo, and keep Ubuntu updated.
