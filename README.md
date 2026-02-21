# Argon ONE V3 Fan Control for OpenWrt

> ⚠️ **UPGRADE NOTICE** ⚠️
> 
> **While this project remains fully functional and usable, a more advanced version is now available.**
> I highly recommend migrating to [**luci-app-argononev3-fancontrol**](https://github.com/ciwga/luci-app-argononev3-fancontrol). 
> The new project features a complete LuCI web interface for OpenWrt, allowing you to easily configure thresholds and monitor temperatures directly from your browser without using the command line.

A lightweight, production-grade fan control daemon specifically designed for the **Argon ONE V3 Case** running **OpenWrt** on **Raspberry Pi 5**.

This project provides a silence-focused, hysteresis-aware cooling solution that communicates directly with the Argon ONE MCU via I2C, ensuring your device stays cool without unnecessary noise.

## 🚀 Features

* **Zero-Config Installation:** A single command handles dependencies, downloads, and system configuration.
* **Smart Hysteresis:** Prevents "fan hunting" (rapid on/off cycling) by using intelligent temperature thresholds.
* **Auto-Healing:** The service is managed by `procd` with automatic respawn capability if the process fails.
* **Boot Configuration:** Automatically detects and enables I2C (`dtparam=i2c_arm=on`) in `/boot/config.txt` during installation.
* **Silent Operation:** Fan curves are tuned to prioritize silence, activating active cooling only when necessary.
* **Safe Shutdown:** Sets the fan to a safe speed if the service receives a termination signal.

## ⚙️ How It Works

The daemon (`argon_fan_control.sh`) operates as a background service:
1.  **Polls:** Reads the CPU/SoC thermal zone every **5 seconds**.
2.  **Logic:** Compares the temperature against defined thresholds with hysteresis logic.
3.  **Actuates:** Sends I2C commands (Address `0x1a`) to the Argon MCU only when a speed change is required or a heartbeat is needed.

### Fan Speed Thresholds
| Temperature (°C) | Fan Speed | Mode | Description |
| :--- | :--- | :--- | :--- |
| **< 40°C** | 0% | OFF | Passive cooling only |
| **40°C - 44°C** | 10% | QUIET | Silent airflow |
| **45°C - 54°C** | 25% | LOW | Light workloads |
| **55°C - 59°C** | 55% | MEDIUM | Moderate load (Safe Mode) |
| **≥ 60°C** | 100% | HIGH | Active emergency cooling |

## 📋 Prerequisites

* **Hardware:** Raspberry Pi 5 + Argon ONE V3 Case.
* **OS:** OpenWrt (Snapshot or Stable release compatible with RPi 5).
* **Internet:** Required for the installer to fetch dependencies (`i2c-tools`).

## 📦 Installation (Recommended)

The easiest way to install is using the automated installer script. It will handle dependencies, file placement, and boot configuration.

1.  **Connect to your OpenWrt device** via SSH.
2.  **Run the following command:**

```bash
wget -O - [https://raw.githubusercontent.com/ciwga/argon-one-v3-fan-openwrt/main/install.sh](https://raw.githubusercontent.com/ciwga/argon-one-v3-fan-openwrt/main/install.sh) | sh
```

3.  **Reboot your device** (Required to enable the I2C bus):

```bash
reboot
```

That's it! The fan control service will start automatically on boot.

## 🛠 Manual Installation (Advanced)

If you prefer to install manually without the script:

1.  **Install Dependencies:**
    ```bash
    opkg update
    opkg install i2c-tools
    ```

2.  **Enable I2C:**
    Edit `/boot/config.txt` and ensure this line exists:
    ```text
    dtparam=i2c_arm=on
    ```

3.  **Download & Install Files:**
    * Download `argon_fan_control.sh` to `/usr/bin/` and `chmod +x`.
    * Download `files/argon_daemon.init` to `/etc/init.d/argon_daemon` and `chmod +x`.

4.  **Enable Service:**
    ```bash
    /etc/init.d/argon_daemon enable
    /etc/init.d/argon_daemon start
    ```

## 🔍 Troubleshooting & Usage

### Check Service Status
```bash
service argon_daemon status
```

### View Real-time Logs
The daemon logs to the system log (syslog). You can view the output:
```bash
logread -e argon_daemon
```
*Example Output:* `[INFO] State Changed: 56C -> Fan Level: 3 (0x37)`

### Verify I2C Connection
If the fan is not responding, check if the system detects the Argon MCU:
```bash
i2cdetect -y 1
```
* **Success:** You see `1a` or `UU` at row `10`, column `a`.
* **Failure:** The table is empty. Check `/boot/config.txt` and reboot.


## 📄 License
MIT / GPLv3 License. See [LICENSE](LICENSE) for details.

Maintained by **ciwga** (2026)
