#!/usr/bin/env bash
# Apply or clear kid internet nftables policy.
# Used by familyd; can also be invoked manually for debugging.
# Usage: family-net.sh allow|block [kid_username]
set -euo pipefail

ACTION="${1:-}"
KID_USER="${2:-kid}"
TABLE="family_kiosk"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Must run as root" >&2
  exit 1
fi

UID_NUM="$(id -u "$KID_USER")"

case "$ACTION" in
  allow)
    nft -f - <<EOF
flush table inet ${TABLE}
table inet ${TABLE} {
  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF
    mkdir -p /var/lib/family-kiosk
    echo 1 >/var/lib/family-kiosk/internet_allowed
    echo "Internet ALLOWED for uid ${UID_NUM}"
    ;;
  block)
    nft -f - <<EOF
flush table inet ${TABLE}
table inet ${TABLE} {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid ${UID_NUM} oifname "lo" accept
    meta skuid ${UID_NUM} udp dport 53 accept
    meta skuid ${UID_NUM} tcp dport 53 accept
    meta skuid ${UID_NUM} tcp dport 8787 accept
    meta skuid ${UID_NUM} reject
  }
}
EOF
    mkdir -p /var/lib/family-kiosk
    echo 0 >/var/lib/family-kiosk/internet_allowed
    echo "Internet BLOCKED for uid ${UID_NUM}"
    ;;
  *)
    echo "Usage: $0 allow|block [kid_username]" >&2
    exit 2
    ;;
esac
