# Pi Zero 2 W as Colok's second radio

A Mac cannot broadcast Wi-Fi while Wi-Fi is its uplink — one radio can't be
client and access point at once. This board is the second radio.

```
filtered Wi-Fi ──▶ Mac en0   (only whitelisted MAC on the network)
                     │  macOS Internet Sharing: Wi-Fi in → USB out
                     ▼
                 USB cable  (CDC-ECM; carries data and power)
                     ▼
                 Pi usb0
                     │  NAT + DHCP (NetworkManager shared mode)
                     ▼
                 SoftAP ──▶ iPhone, Android, anything
```

Everything downstream is double-NATed. Clients don't care, and the upstream
network only ever sees the Mac.

## Buy

| item | note |
|---|---|
| Raspberry Pi Zero 2 W | ~$15. The plain Zero W works but is noticeably slower. |
| microSD, 8 GB+ | Raspberry Pi OS Lite is enough; no desktop needed. |
| USB-A to micro-B **data** cable | Charge-only cables are the most common failure. |

No Ethernet adapter and no power supply — the Mac's USB port does both.

## Flash and provision

1. Raspberry Pi Imager → **Raspberry Pi OS Lite (64-bit)**. In the settings gear,
   set a hostname, enable SSH, and set a user. Wi-Fi credentials are optional —
   `wlan0` becomes the access point, so it won't be joining anything.

2. Boot the Pi, get a shell on it, then:

   ```sh
   sudo SSID=Colok PSK=your-password COUNTRY=ID bash setup.sh
   sudo reboot
   ```

   `COUNTRY` is not cosmetic — without a regulatory domain the radio stays
   rfkill-blocked and the AP never appears.

3. Plug the Pi into the Mac using the port marked **USB**, not **PWR**.

## Mac side

```sh
colok share list        # the Pi shows up as an en* output
colok share on <en*>
```

Or flip the **Wireless (Internet Sharing)** toggle in the menu bar. Phones then
join the SSID you set.

## What to expect

Roughly 40–50 Mbps, 2.4 GHz only (the Zero 2 W has no 5 GHz radio). That is a
ceiling worth knowing, but on a congested uplink the stable path usually beats a
faster jittery one.

## Worth doing: run the proxy here

The Pi is a full Linux box, so it can run an HTTP proxy that terminates TCP
locally. That matters for iPhones: tethered caching bridges them transparently,
so their TCP sees the full jittery path and the congestion window collapses.
Joining the Pi's AP instead gives a normal Wi-Fi network with a **Configure
Proxy** field — which a tethered-caching link does not have. That is the same
split-TCP advantage that makes Colok's Android lane fast.

## If it doesn't come up

| symptom | cause |
|---|---|
| No `en*` appears on the Mac | Charge-only cable, or plugged into `PWR` |
| `usb0` has no address | The Mac isn't sharing yet — run `colok share on` |
| No SSID broadcast | Regulatory domain unset; `sudo raspi-config nonint do_wifi_country ID` |
| Clients join, no internet | Check `ip route` on the Pi has a default via `usb0` |
