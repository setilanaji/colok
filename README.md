# Colok

Share this Mac's internet with USB-attached phones, when the phones can't join
the Wi-Fi themselves.

## Why it works this way

A Mac **cannot** broadcast a Wi-Fi hotspot while Wi-Fi is its internet source.
One radio can't be station and access point at once, so macOS greys Wi-Fi out
under "To devices using" whenever the source is Wi-Fi. No entitlement or private
API changes that, and USB Wi-Fi dongles have no AP-mode drivers on Apple Silicon.

So Colok goes over the cable instead. Two different mechanisms, because the two
platforms offer nothing in common:

| | mechanism | needs |
|---|---|---|
| iPhone / iPad | macOS **tethered caching** (Content Caching + `AssetCacheTetheratorUtil`) — the same path device carts and Apple Configurator use | a cable, device unlocked and trusting this Mac |
| Android | **gnirehtet** — a VpnService on the phone tunnelling all IPv4 TCP/UDP over `adb reverse` into a relay here | USB debugging on, `adb`, the relay + APK |

### Without a cable

The third lane drives macOS Internet Sharing, which is the only cable-free path,
because the Mac's own radio can never do it alone:

| shape | what you need | result |
|---|---|---|
| Ethernet in → **Wi-Fi out** | a wired port on the network + USB-C Ethernet adapter | a real hotspot from the Mac |
| Wi-Fi in → **Ethernet out** | USB-C Ethernet adapter + a pocket router (GL.iNet Mango and similar) | the router broadcasts; phones join it |

Wi-Fi in → Wi-Fi out is refused by macOS and rejected by Colok before it writes
anything: one radio cannot be a client and an access point at the same time.

If you have no Ethernet adapter, [`hardware/pi-zero-2w/`](hardware/pi-zero-2w/)
turns a $15 Raspberry Pi Zero 2 W into that second radio over a single USB
cable — no adapter, no separate power.

Internet Sharing needs root writes to `com.apple.nat.plist`. Whitelisting
`defaults` under sudo would be equivalent to handing out a root shell, so Colok
installs `/usr/local/libexec/colok-share` instead — root-owned, mode 0755, and it
validates every argument (interface names, service UUID, SSID) itself. Sudoers
permits that one path and nothing else.

Check what it found before toggling anything:

```sh
colok share list      # uplink, and every output interface with a live link
colok share on        # or: colok share on en5 MySSID
```

Both USB lanes NAT through whatever uplink the Mac has, so from the network's point of
view all traffic comes from this Mac's already-permitted MAC address. This is
ordinary NAT, not address spoofing.

## Setup

```sh
make bundle                              # builds Colok.app
sudo bash Scripts/install-sudoers.sh     # one-time, two whitelisted commands
bash Scripts/fetch-gnirehtet.sh          # Android lane only; needs cargo
make install                             # optional: /Applications + colok CLI
```

`install-sudoers.sh` writes `/etc/sudoers.d/colok`, granting your user exactly
`AssetCacheManagerUtil activate|deactivate` and `AssetCacheTetheratorUtil
enable|disable|isEnabled` with fixed arguments — nothing wildcarded. It runs
`visudo -c` before installing so a malformed rule can never lock you out of
sudo. Undo with `sudo rm /etc/sudoers.d/colok`.

## Use

Click the menu bar icon. Plug a device in. iOS devices come up automatically
once the lane is on; Android devices get a Start button, because gnirehtet has
to push a VPN consent prompt the first time.

CLI equivalent:

```sh
colok status
colok doctor          # what's missing and where
colok on              # everything attached, online
colok off
```

## Known limits

- gnirehtet is IPv4 TCP/UDP only. No IPv6, no raw ICMP — `ping` from the phone
  won't work even when browsing does.
- gnirehtet is no longer actively maintained upstream; it still builds and runs.
- Throughput is bounded by the relay, not USB. Fine for testing and browsing,
  not for pulling a 4 GB OS update onto four devices at once.
- Tethered caching wants the Mac awake and on power. A sleeping laptop drops
  every device.
- First connection to an iPhone needs the device unlocked and Trust granted.
- Sharing out over Wi-Fi: macOS has a long-standing bug where a WPA password set
  through the plist is ignored and the network comes up **open**. Set the password
  once in System Settings → General → Sharing → Internet Sharing if that bites.
- `colok-share` backs up any existing `com.apple.nat.plist` to
  `com.apple.nat.plist.colok-backup` before overwriting it.

## Layout

```
Sources/ColokCore    engine: shell, privilege, both lanes, uplink detection
Sources/colok        CLI
Sources/ColokBar     MenuBarExtra UI
Scripts/             sudoers rule, gnirehtet fetch/build
```

## Third-party

`Scripts/fetch-gnirehtet.sh` downloads and builds
[gnirehtet](https://github.com/Genymobile/gnirehtet) (Apache-2.0) into
`~/.colok`. It is not vendored in this repository; nothing from it is
redistributed here.

## License

MIT - see [LICENSE](LICENSE).
