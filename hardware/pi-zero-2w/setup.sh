#!/bin/bash
# Provision a Raspberry Pi Zero 2 W as Colok's second radio.
#
#   filtered Wi-Fi -> Mac (whitelisted MAC) -> USB gadget -> this Pi -> SoftAP
#
# Only the Mac's MAC address ever appears on the upstream network. Everything
# downstream sits behind two layers of NAT, which clients do not care about.
#
# Run ON THE PI, as root, on Raspberry Pi OS Bookworm or later:
#   sudo SSID=Colok PSK=your-password bash setup.sh
set -euo pipefail

SSID="${SSID:-Colok}"
PSK="${PSK:-}"
COUNTRY="${COUNTRY:-ID}"      # regulatory domain; the radio stays rfkill'd without one
AP_CON="colok-ap"
BOOT_DIR="/boot/firmware"     # Bookworm; older images use /boot

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
[[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"

if [[ -z "$PSK" || ${#PSK} -lt 8 ]]; then
  echo "set PSK to at least 8 characters:  sudo SSID=Colok PSK=something bash setup.sh" >&2
  exit 1
fi

echo "==> 1/5 USB Ethernet gadget"
# dwc2 puts the USB port in device mode; g_ether presents CDC-ECM, which macOS
# supports natively (it does not speak RNDIS).
if ! grep -q '^dtoverlay=dwc2' "$BOOT_DIR/config.txt"; then
  printf '\n# Colok: USB device mode\ndtoverlay=dwc2\n' >> "$BOOT_DIR/config.txt"
  echo "    added dtoverlay=dwc2"
else
  echo "    dtoverlay=dwc2 already present"
fi

if ! grep -q 'modules-load=dwc2,g_ether' "$BOOT_DIR/cmdline.txt"; then
  # cmdline.txt must stay a single line.
  sed -i 's/rootwait/rootwait modules-load=dwc2,g_ether/' "$BOOT_DIR/cmdline.txt"
  echo "    added modules-load=dwc2,g_ether"
else
  echo "    g_ether already in cmdline"
fi

echo "==> 2/5 regulatory domain ($COUNTRY)"
raspi-config nonint do_wifi_country "$COUNTRY" 2>/dev/null || \
  iw reg set "$COUNTRY" 2>/dev/null || echo "    could not set country automatically"
rfkill unblock wifi 2>/dev/null || true

echo "==> 3/5 IP forwarding"
install -d /etc/sysctl.d
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-colok.conf
sysctl -q -w net.ipv4.ip_forward=1

echo "==> 4/5 access point on wlan0"
# NetworkManager's "shared" mode brings its own DHCP and masquerading, so there
# is no hostapd/dnsmasq/iptables stack to keep in sync. Upstream is whatever
# holds the default route - usb0, once the Mac starts sharing.
nmcli connection delete "$AP_CON" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname wlan0 mode ap con-name "$AP_CON" ssid "$SSID"
nmcli connection modify "$AP_CON" \
  802-11-wireless.band bg \
  802-11-wireless.channel 6 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.proto rsn \
  wifi-sec.pairwise ccmp \
  wifi-sec.psk "$PSK" \
  ipv4.method shared \
  ipv6.method ignore \
  connection.autoconnect yes
nmcli connection up "$AP_CON"

echo "==> 5/5 usb0 as a DHCP client"
# macOS Internet Sharing hands out 192.168.2.x on the shared interface.
nmcli connection modify "Wired connection 1" ipv4.method auto 2>/dev/null || true

cat <<EOF

Done. Reboot for the USB gadget to come up:  sudo reboot

Then, on the Mac:
  colok share list                 # the Pi appears as an en* output
  colok share on <en*>             # or use the Wireless lane in the menu bar

Phones join SSID "$SSID".

If the Pi gets no address on usb0, the usual causes are a charge-only USB
cable or the cable being in the PWR port instead of the USB one.
EOF
