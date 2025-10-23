#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-usb-priority.sh
# ---------------------
# Purpose:
#   Configure Raspberry Pi Zero 2 W to prefer USB Ethernet gadget (usb0) with
#   DHCP from Windows ICS, and use Wi‑Fi as fallback via NetworkManager.
#
# Assumptions:
#   - Raspberry Pi OS Bookworm (NetworkManager as default).
#   - Pi is already reachable over Wi‑Fi (SSH works).
#   - USB data cable connected to the Pi's USB (OTG) port (not PWR IN).
#
# What this script does:
#   1) Ensures dwc2/g_ether gadget is enabled (config.txt + cmdline.txt).
#   2) Ensures NetworkManager manages usb0.
#   3) Removes duplicate usb0 profiles (keeps the active one).
#   4) Sets usb0 to DHCP with route metric 100 (priority).
#   5) Sets Wi‑Fi connection (default: "preconfigured") to metric 600 (fallback).
#   6) Restarts connections and prints status + quick egress check.
#
# Usage:
#   sudo bash scripts/setup-usb-priority.sh
#
# Adjustables (top-level variables):
#   - USB_IF, USB_CONN_NAME, WIFI_CONN_NAME, USB_METRIC, WIFI_METRIC
#
# Notes:
#   - After changing overlays/cmdline, a reboot is required once.
#   - Avoid running dhclient manually afterward; let NetworkManager handle DHCP.
# -----------------------------------------------------------------------------

set -euo pipefail

USB_IF="usb0"
USB_CONN_NAME="usb0"
WIFI_CONN_NAME="preconfigured"   # change if your Wi‑Fi profile has a different name
USB_METRIC=100                   # higher priority (lower number)
WIFI_METRIC=600                  # fallback

NM_CONF_DIR="/etc/NetworkManager/conf.d"
USB_MANAGED_CONF="$NM_CONF_DIR/98-usb0-managed.conf"

echo "==> Ensuring USB gadget overlays (dwc2 + g_ether) ..."
CFG="/boot/firmware/config.txt"
CMD="/boot/firmware/cmdline.txt"

# Add dtoverlay=dwc2 if missing (separate line)
if ! grep -qE '^\s*dtoverlay=dwc2(\s*$|,|#)' "$CFG"; then
  echo 'dtoverlay=dwc2' | sudo tee -a "$CFG" >/dev/null
fi

# Ensure modules-load=dwc2,g_ether on the single cmdline
if ! grep -q 'modules-load=dwc2,g_ether' "$CMD"; then
  sudo cp "$CMD" "${CMD}.bak.$(date +%s)"
  sudo sed -i '1s/$/ modules-load=dwc2,g_ether/' "$CMD"
  echo "   -> cmdline.txt updated. Reboot required to apply this if it was missing."
fi

echo "==> Let NetworkManager manage $USB_IF ..."
sudo nmcli device set "$USB_IF" managed yes || true

echo "==> Making $USB_IF managed persistently ..."
sudo install -d -m 755 "$NM_CONF_DIR"
sudo tee "$USB_MANAGED_CONF" >/dev/null <<EOF
[device]
match-device=interface-name:${USB_IF}
managed=1
EOF
if grep -REq "unmanaged-devices=.*interface-name:${USB_IF}" "$NM_CONF_DIR" 2>/dev/null; then
  offenders=$(grep -Rl "unmanaged-devices=.*interface-name:${USB_IF}" "$NM_CONF_DIR" 2>/dev/null | paste -sd ', ' -)
  echo "   -> Warning: ${USB_IF} is still marked unmanaged in: ${offenders}"
  echo "      Remove or adjust those entries if the device stays unmanaged after reboot."
fi

echo "==> Normalize duplicate connections named $USB_CONN_NAME ..."
ACTIVE_UUID="$(nmcli -t -f NAME,UUID,TYPE,DEVICE con show --active | awk -F: -v n="$USB_CONN_NAME" '$1==n && $3 ~ /ethernet/{print $2; exit}')"
if [ -n "$ACTIVE_UUID" ]; then
  # delete any inactive duplicates
  while IFS=: read -r NAME UUID TYPE DEV STATE; do
    if [ "$NAME" = "$USB_CONN_NAME" ] && [[ "$TYPE" =~ ethernet ]] && [ "$UUID" != "$ACTIVE_UUID" ]; then
      sudo nmcli con delete "$UUID" || true
      echo "   -> Deleted duplicate $UUID"
    fi
  done < <(nmcli -t -f NAME,UUID,TYPE,DEVICE,STATE con show)
else
  # no active usb0 profile yet
  CAND_UUID="$(nmcli -t -f NAME,UUID,TYPE con show | awk -F: -v n="$USB_CONN_NAME" '$1==n && $3 ~ /ethernet/{print $2; exit}')"
  if [ -n "$CAND_UUID" ]; then
    ACTIVE_UUID="$CAND_UUID"
  else
    echo "   -> Creating connection $USB_CONN_NAME..."
    sudo nmcli con add type ethernet ifname "$USB_IF" con-name "$USB_CONN_NAME" || true
    ACTIVE_UUID="$(nmcli -t -f NAME,UUID,TYPE con show | awk -F: -v n="$USB_CONN_NAME" '$1==n && $3 ~ /ethernet/{print $2; exit}')"
  fi
fi

if [ -z "$ACTIVE_UUID" ]; then
  echo "❌ Error: unable to determine UUID for connection '$USB_CONN_NAME'."
  echo "   -> Inspect existing connections with: nmcli -t -f NAME,UUID,TYPE con show"
  exit 1
fi

echo "==> Configure $USB_CONN_NAME ($ACTIVE_UUID) for DHCP and priority ..."
sudo nmcli con modify "$ACTIVE_UUID" \
  connection.id "$USB_CONN_NAME" \
  connection.interface-name "$USB_IF" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  802-3-ethernet.mac-address "" \
  802-3-ethernet.cloned-mac-address "" \
  ipv4.method auto \
  ipv4.never-default no \
  ipv4.route-metric "$USB_METRIC" \
  ipv6.method ignore

# NetworkManager caches the permanent MAC; when gadget randomizes each boot,
# clear any stale reference so activation does not fail on mismatch.
if nmcli --help 2>&1 | grep -q 'assigned-mac-address'; then
  sudo nmcli con modify "$ACTIVE_UUID" 802-3-ethernet.assigned-mac-address "" || true
fi

echo "==> Configure Wi‑Fi ($WIFI_CONN_NAME) as fallback (metric $WIFI_METRIC) ..."
if nmcli -t -f NAME con show | grep -qx "$WIFI_CONN_NAME"; then
  sudo nmcli con modify "$WIFI_CONN_NAME" \
    connection.autoconnect yes \
    ipv4.never-default no \
    ipv4.route-metric "$WIFI_METRIC" \
    ipv6.method auto
else
  echo "   -> Warning: Wi‑Fi connection '$WIFI_CONN_NAME' not found. Skipping."
fi

echo "==> Restarting connections ..."
sudo nmcli con down "$USB_CONN_NAME" 2>/dev/null || true
sudo ip addr flush dev "$USB_IF" || true
sudo nmcli con up "$USB_CONN_NAME" || true
[ -n "${WIFI_CONN_NAME:-}" ] && sudo nmcli con up "$WIFI_CONN_NAME" 2>/dev/null || true

echo "==> Status:"
ip addr show "$USB_IF" | sed 's/^/   /'
echo
ip route | sed 's/^/   /'
echo
echo "==> Quick egress check (curl -4 ifconfig.me):"
if command -v curl >/dev/null 2>&1; then
  curl -4 --max-time 5 ifconfig.me || true
  echo
else
  echo "   -> Install curl for this test: sudo apt-get update && sudo apt-get install -y curl"
fi

echo "✅ Done: usb0 prioritized (DHCP via Windows ICS), Wi‑Fi fallback."
echo "   If you just edited cmdline/config for dwc2/g_ether, reboot with: sudo reboot"
