from __future__ import annotations

import logging
import pwd
import shutil
import subprocess
from pathlib import Path

from familyd.config import AppConfig

log = logging.getLogger("familyd.network")

NFT_TABLE = "family_kiosk"
STATE_DIR = Path("/var/lib/family-kiosk")
ALLOW_FILE = STATE_DIR / "internet_allowed"


def resolve_kid_uid(username: str) -> int | None:
    try:
        return pwd.getpwnam(username).pw_uid
    except KeyError:
        log.warning("Kid user %r not found", username)
        return None
    except Exception:
        # Non-Linux (e.g. macOS without that user) — fine in dry-run.
        return None


def apply_internet_policy(cfg: AppConfig, internet_allowed: bool) -> None:
    """Toggle general outbound internet for the kid UID.

    Always-allow domains are handled by the local allowlist proxy when
    internet is blocked. This helper focuses on a coarse UID gate via nftables.
    """
    if cfg.dry_run_network:
        log.info(
            "[dry-run] internet_allowed=%s for user=%s",
            internet_allowed,
            cfg.kid_username,
        )
        return

    if shutil.which("nft") is None:
        log.error("nft not found; cannot apply network policy")
        return

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    ALLOW_FILE.write_text("1" if internet_allowed else "0", encoding="utf-8")

    uid = resolve_kid_uid(cfg.kid_username)
    if uid is None:
        log.error("Cannot resolve kid UID; skipping nftables")
        return

    # Flush and recreate a dedicated table so we own the rules cleanly.
    # When blocked: kid UID may only talk to loopback, DNS, and familyd.
    # The allowlist proxy runs as a system user and is not subject to this filter.
    if internet_allowed:
        script = f"""
flush table inet {NFT_TABLE}
table inet {NFT_TABLE} {{
  chain output {{
    type filter hook output priority 0; policy accept;
  }}
}}
"""
    else:
        script = f"""
flush table inet {NFT_TABLE}
table inet {NFT_TABLE} {{
  chain output {{
    type filter hook output priority 0; policy accept;
    meta skuid {uid} oifname "lo" accept
    meta skuid {uid} udp dport 53 accept
    meta skuid {uid} tcp dport 53 accept
    meta skuid {uid} tcp dport 8787 accept
    meta skuid {uid} reject
  }}
}}
"""

    proc = subprocess.run(
        ["nft", "-f", "-"],
        input=script,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        log.error("nftables apply failed: %s", proc.stderr)
    else:
        log.info("nftables updated (internet_allowed=%s)", internet_allowed)


def ensure_policy_bootstrap(cfg: AppConfig) -> None:
    """On startup, enforce default blocked state unless a session is active."""
    apply_internet_policy(cfg, internet_allowed=False)
