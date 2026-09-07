# Family Kiosk

A simple Ubuntu kiosk for a family mini PC (GMKtec G10 and similar). Your child gets a full-screen activity picker — not a normal desktop — with computer hours and parent-approved internet sessions.

## What it does

- **Kid login** opens a GNOME Kiosk session with one screen: Homework (Google with SafeSearch locked), mBlock, Ask for internet, and Web (only while internet is approved).
- **Computer hours** (default Eastern Time): weekdays 4–8 PM, weekends 9 AM–8 PM. Outside those hours the picker shows a closed state.
- **Internet** is off by default. Google / GSuite and mBlock domains stay reachable. Everything else needs a timed approval (15 / 30 / 60 minutes).
- **Explicit content**: Chromium policies force Google SafeSearch (including Images), YouTube Restricted Mode, and SafeSites filtering. See [deploy/GOOGLE-SAFE.md](deploy/GOOGLE-SAFE.md).
- **Parent review** on your iPhone (home Wi‑Fi): open `http://family-pc.local:8787/parent`, enter your PIN, approve or deny. Push notifications can come later.

## Quick start (Mac / browser preview)

```bash
# From your machine (private repo: sign in first — `gh auth login` or SSH keys)
gh repo clone family-kiosk
cd family-kiosk
# Prefer 3.11–3.13. On Mac Homebrew, `python3` may be 3.14 — use python3.13 if unsure.
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

### Install troubleshooting (Mac)

If `pip install` fails with **Failed building wheel for pydantic-core**, your venv is almost certainly on **Python 3.14** while an older pydantic pin tried to compile from source. Recreate the venv with 3.13 (recommended), or pull latest requirements (pydantic 2.13+ has 3.14 wheels):

```bash
brew install python@3.13
rm -rf .venv
python3.13 -m venv .venv
source .venv/bin/activate
python -V   # should show 3.13.x
pip install -r requirements.txt
```

## Ubuntu 24.04 on the G10

1. Install Ubuntu Desktop (wipe Windows). Ryzen 5 3500U / Vega 8 works well. If 2.5GbE is flaky (Realtek RTL8125), use Wi‑Fi.
2. Create your **parent** account during install (full desktop + sudo), and a separate Ubuntu user for your child (Settings → Users).
3. On the parent account, clone this repo and run the installer (it will ask which existing user is the child; or set `KID_USER=username` to skip the prompt):

```bash
sudo apt update && sudo apt install -y git gh
gh auth login    # required once if the repo is private
gh repo clone family-kiosk
cd family-kiosk
sudo bash deploy/install-ubuntu.sh
# optional non-interactive: sudo KID_USER=hisname bash deploy/install-ubuntu.sh
sudo nano /etc/family-kiosk/config.yaml   # change parent_pin, hours, homework sites
sudo systemctl restart familyd
```

4. Log out completely (or reboot), then sign in as the **child** user. You do **not** need a gear icon — the installer sets their default session to GNOME Kiosk.
5. If you still get a normal desktop: `sudo bash deploy/fix-kiosk.sh` then **reboot** and sign in as the child again.
6. On your iPhone (same Wi‑Fi), bookmark **http://family-pc.local:8787/parent**.
7. Verify SafeSearch policies: on the kid session open `chrome://policy`, and set up [Family Link](https://families.google.com/familylink) (or school admin controls) for his Google account — details in [deploy/GOOGLE-SAFE.md](deploy/GOOGLE-SAFE.md).

Note: Ubuntu’s login screen only shows the session gear when multiple sessions are offered. If the kiosk session package was missing, Ubuntu was the only option — so there was no gear and the child kept getting a normal desktop. `fix-kiosk.sh` installs the kiosk session and forces it as the child’s default.

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

## Parent controls

On the kid screen, **Parent** asks for the PIN and opens the parent dashboard (approve internet, etc.). From the dashboard you can **Exit kiosk** to return to the login screen and sign in with the parent Ubuntu account.

See also [deploy/MBLOCK.md](deploy/MBLOCK.md) for robot USB setup and
[deploy/GOOGLE-SAFE.md](deploy/GOOGLE-SAFE.md) for SafeSearch / explicit-content lockdown.

## Network model

- `familyd` runs as root (systemd) and manages an `inet family_kiosk` nftables table.
- When internet is **off**, the kid UID cannot make general outbound connections (loopback, DNS, and port 8787 stay open).
- An allowlist HTTP proxy on `127.0.0.1:8888` lets Homework / mBlock domains through while general web stays blocked.
- When you approve a session, nftables restrictions are cleared until the timer ends.

## Config highlights

Edit `/etc/family-kiosk/config.yaml` (or `config/config.yaml` in dev):

- `parent_pin` — dashboard + kiosk exit
- `hours` — per-day start/end
- `homework_url_allowlist` / `homework_start_url` — Google / school entry points
- `always_allow_domains` — proxy allowlist (Google + mBlock hosts)
- `session_durations` — `[15, 30, 60]`
- `dry_run_network: true` on Mac; `false` on the G10

## Security notes

This is a home appliance control layer, not a hardened enterprise lockdown. A determined user with physical access and time can still find ways around kiosk Chromium. Keep the parent account password strong, do not give the kid sudo, and keep Ubuntu updated.
