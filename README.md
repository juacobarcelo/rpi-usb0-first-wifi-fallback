# rpi-usb0-first-wifi-fallback

**Tools and scripts to make Raspberry Pi Zero 2 W prefer USB Ethernet (usb0) via Windows ICS, with Wi‑Fi failover using NetworkManager. DHCP enabled.**

This guide sets up a Raspberry Pi Zero 2 W so it exposes a USB Ethernet gadget (`usb0`) to a Windows host. Windows shares its Internet connection (ICS) over that USB link, and the Pi prefers `usb0` (metric 100) with Wi‑Fi as a fallback (metric 600).

It includes two scripts:

* **Windows (PowerShell)** – force ICS from your Internet adapter to the RNDIS adapter.
* **Raspberry Pi (bash)** – configure NetworkManager to use DHCP on `usb0` with higher priority than Wi‑Fi.

> Tested on Raspberry Pi OS (Bookworm, NetworkManager) and Windows 10/11.

---

## Table of contents

* [Prerequisites](#prerequisites)
* [Wiring & Overview](#wiring--overview)
* [Windows Setup (Host)](#windows-setup-host)
* [Raspberry Pi Setup](#raspberry-pi-setup)
* [Verification](#verification)
* [Troubleshooting](#troubleshooting)
* [Scripts](#scripts)

  * [`setup-ics-rndis.ps1` (Windows)](#setup-ics-rndisps1-windows)
  * [`setup-usb-priority.sh` (Raspberry Pi)](#setup-usb-prioritysh-raspberry-pi)
* [Notes & Gotchas](#notes--gotchas)

---

## Prerequisites

* **Raspberry Pi Zero 2 W** running Raspberry Pi OS Bookworm (uses NetworkManager by default), **already operational and reachable over Wi‑Fi**.
* You can already connect to the Pi from the Windows host over Wi‑Fi (SSH or similar) before starting this guide.
* **Windows 10/11** PC with an active Internet connection (Ethernet or Wi‑Fi).
* **USB data cable** (micro‑USB *data*, not power‑only) connected to the Pi’s **USB** port (not the PWR IN).
* If Windows doesn’t auto‑install the RNDIS driver, install a **Remote NDIS Compatible Device** driver. One option used successfully: [https://github.com/dukelec/mbrush/tree/master/doc/win_driver](https://github.com/dukelec/mbrush/tree/master/doc/win_driver).

---

## Wiring & Overview

1. Connect the Pi’s **USB** (OTG) port to the Windows PC with a data‑capable cable.
2. The Pi loads **dwc2** + **g_ether** (USB Ethernet gadget) → Windows sees an RNDIS adapter.
3. Windows **ICS** (Internet Connection Sharing) NATs/forwards traffic from its Internet adapter to the RNDIS adapter and provides **DHCP** on **192.168.137.0/24**.
4. On the Pi, NetworkManager uses **DHCP** on `usb0` with **route metric 100**; Wi‑Fi uses **metric 600** as backup.

---

## Windows Setup (Host)

1. **Install/Enable RNDIS**

* Plug the Pi (USB data) → Windows should show a new network adapter.
* If it appears with a warning icon ("USB Ethernet/RNDIS Gadget"), install the driver:

  * *Device Manager* → device → **Update driver** → **Browse my computer** → **Let me pick** → **Network adapters** → **Microsoft** → **Remote NDIS Compatible Device**.
* (Optional) Rename the adapter to **`RNDIS-rpi`** for clarity.

2. **Enable ICS (Share Internet → RNDIS-rpi)**

* `Win+R` → `ncpa.cpl`.
* Right‑click your **Internet** adapter (e.g., *Ethernet* with Internet access) → **Properties** → **Sharing**.
* Check **Allow other network users to connect…** and choose **`RNDIS-rpi`** as the **Home networking connection**.
* After enabling ICS, Windows assigns **192.168.137.1/24** to the RNDIS adapter and starts DHCP/NAT.

3. **If the UI won’t let you pick the “Home” interface**

* Use the PowerShell script below [`setup-ics-rndis.ps1`](#setup-ics-rndisps1-windows) to force ICS from your Internet adapter (default: `"Ethernet"`) to `"RNDIS-rpi"`.

4. **Services and firewall (required by ICS)**

* Ensure **Windows Firewall** is **enabled** and services are running:

  ```powershell
  Start-Service MpsSvc
  Start-Service SharedAccess
  ```

---

## Raspberry Pi Setup

1. **Enable the USB Ethernet gadget**

* Edit `/boot/firmware/config.txt` and ensure overlays are separate lines:

  ```ini
  dtoverlay=dwc2
  ```

  (If you use the HQ camera overlay too, keep it as a separate line, e.g. `dtoverlay=imx477`.)
* Edit `/boot/firmware/cmdline.txt` – on the single kernel line, append:

  ```
  modules-load=dwc2,g_ether
  ```
* Reboot if you changed these files.

2. **Confirm the gadget interface**

```bash
lsmod | egrep 'dwc2|g_ether'
ip link show usb0
```

3. **Configure NetworkManager**

* Use the script below [`setup-usb-priority.sh`](#setup-usb-prioritysh-raspberry-pi) (sets `usb0` to DHCP with metric 100 and Wi‑Fi profile `preconfigured` to metric 600), or run equivalent `nmcli` commands manually.

If you want to inspect or manually bring the connection up on the Pi:

```bash
# List saved connections (all / active)
nmcli connection show
nmcli connection show --active

# Show device state and controllers
nmcli device status

# Bring usb0 online through NetworkManager
sudo nmcli connection up usb0
```

The helper script also writes `/etc/NetworkManager/conf.d/98-usb0-managed.conf` so the gadget stays managed after reboots. If `nmcli device status` still lists `usb0` as `unmanaged`, check `/etc/NetworkManager/conf.d/*.conf` for `unmanaged-devices=interface-name:usb0` entries and remove them.

---

## Verification

On the **Pi**:

```bash
# IP assigned by Windows ICS, e.g., 192.168.137.x
ip addr show usb0

# Default route should prefer usb0 (metric 100); Wi‑Fi is backup (metric 600)
ip route

# Which interface is used to reach the Internet?
ip route get 8.8.8.8   # should show "dev usb0"

# Gateway reachability (Windows ICS gateway)
ping -c3 192.168.137.1

# Public egress
curl -4 ifconfig.me
```

Optionally compare egress per interface:

```bash
curl --interface usb0 -4 ifconfig.me; echo
curl --interface wlan0 -4 ifconfig.me; echo
```

---

## Troubleshooting

* **RNDIS shows 169.254.x.x on Windows** → ICS is not applied to the RNDIS adapter. Re‑enable ICS or run `setup-ics-rndis.ps1`. After ICS, RNDIS should be **192.168.137.1/24**.
* **Pi doesn’t get a DHCP address on `usb0`**

  * On Windows (PowerShell admin):

    ```powershell
    Get-Service MpsSvc, SharedAccess  # both should be Running
    Get-NetIPConfiguration -InterfaceAlias "RNDIS-rpi"  # IPv4Address should be 192.168.137.1
    Get-NetUDPEndpoint -LocalPort 67  # ICS DHCP listener
    ```
  * On the Pi:

    ```bash
    sudo ip addr flush dev usb0
    sudo dhclient -v usb0
    ```
  * Fallback to **static** on the Pi (works fine with ICS):

    ```bash
    nmcli con modify usb0 ipv4.method manual \
      ipv4.addresses 192.168.137.2/24 ipv4.gateway 192.168.137.1 ipv4.dns 192.168.137.1
    nmcli con up usb0
    ```
* **Multiple `usb0` connections in NetworkManager** → Keep only the active one; delete duplicates with `nmcli con delete <UUID>`.

---

## Scripts

The scripts are provided as separate files for reuse and versioning:

* **Windows (PowerShell):** [`scripts/setup-ics-rndis.ps1`](scripts/setup-ics-rndis.ps1)

  * Enables Internet Connection Sharing (ICS) from your Internet adapter to the RNDIS adapter.
  * Ensures required services and firewall are enabled, sets the RNDIS profile to *Private*, binds ICS, and verifies DHCP (192.168.137.1) and the UDP/67 listener.
  * **Usage (PowerShell as Administrator):**

    ```powershell
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    .\scripts\setup-ics-rndis.ps1
    ```

* **Raspberry Pi (bash):** [`scripts/setup-usb-priority.sh`](scripts/setup-usb-priority.sh)

  * Configures NetworkManager to use DHCP on `usb0` with higher priority (metric 100) and sets Wi‑Fi fallback (metric 600).
  * Cleans up duplicate `usb0` profiles, ensures `dwc2`/`g_ether` overlays are set, and performs quick connectivity checks.
  * **Usage (on the Pi):**

    ```bash
    sudo bash scripts/setup-usb-priority.sh
    ```

> Adjust adapter/connection names inside each script if your environment differs (they are self‑documented and have clear variables at the top).

---

## Notes & Gotchas

* ICS always uses **192.168.137.0/24** and assigns **192.168.137.1** to the “Home” adapter (RNDIS). If you see **169.254.x.x** on RNDIS, ICS is not applied.
* Windows Firewall must be **enabled** (ICS depends on it).
* If DHCP misbehaves, you can run the Pi with a **static** IP like `192.168.137.2/24` (GW/DNS `192.168.137.1`) and still use ICS NAT/DNS.
* Linux route selection is by **metric** (lower = higher priority). We use `usb0=100`, Wi‑Fi=600.

---

## Contributing

1. Open a short issue if your change is more than a quick fix so we can align on scope.
2. Submit your updates through a pull request and include any manual test notes or extra setup steps.
3. All merges require approval from the project maintainer before they land in `main`.

---

## License

Released under the [MIT License](LICENSE).

---

Happy hacking! PRs welcome if you find improvements or different adapter names in your setup.
