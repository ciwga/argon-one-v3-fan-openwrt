#!/bin/sh

# ==============================================================================
# Argon ONE V3 Fan Control Installer for OpenWrt (Raspberry Pi 5)
# Author: ciwga
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
REPO_USER="ciwga"
REPO_NAME="argon-one-v3-fan-openwrt"
BRANCH="main"

BASE_URL="https://raw.githubusercontent.com/$REPO_USER/$REPO_NAME/$BRANCH"
MAIN_SCRIPT_URL="$BASE_URL/argon_fan_control.sh"
INIT_SCRIPT_URL="$BASE_URL/files/argon_daemon.init"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# INSTALLATION PROCESS
# ------------------------------------------------------------------------------

echo "========================================================"
echo "   Argon ONE V3 Fan Control Installer (OpenWrt/RPi5)    "
echo "========================================================"

# 1. Check Root Privileges
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

# 2. Install Dependencies
log_info "Updating package lists and installing dependencies..."
opkg update >/dev/null 2>&1

if opkg install i2c-tools; then
    log_info "Dependencies installed successfully."
else
    log_err "Failed to install packages. Check your internet connection."
    exit 1
fi

# 3. Download Scripts
log_info "Downloading application files..."

# Download Main Daemon Script
if wget --no-check-certificate -q -O /usr/bin/argon_fan_control.sh "$MAIN_SCRIPT_URL"; then
    chmod +x /usr/bin/argon_fan_control.sh
    log_info "Main script installed to /usr/bin/argon_fan_control.sh"
else
    log_err "Failed to download main script. Check REPO_USER/URL."
    exit 1
fi

# Download Init (Service) Script
if wget --no-check-certificate -q -O /etc/init.d/argon_daemon "$INIT_SCRIPT_URL"; then
    chmod +x /etc/init.d/argon_daemon
    log_info "Service script installed to /etc/init.d/argon_daemon"
else
    log_err "Failed to download init script."
    exit 1
fi

# 4. Configure /boot/config.txt for I2C
CONFIG_FILE="/boot/config.txt"
I2C_PARAM="dtparam=i2c_arm=on"

log_info "Checking I2C configuration..."

if [ -f "$CONFIG_FILE" ]; then
    if grep -q "^$I2C_PARAM" "$CONFIG_FILE"; then
        log_info "I2C is already enabled in config.txt."
    else
        log_info "Enabling I2C support..."
        
        # Create backup
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
        log_info "Backup created: $CONFIG_FILE.bak"

        # Append config
        echo "" >> "$CONFIG_FILE"
        echo "# Added by Argon ONE Installer" >> "$CONFIG_FILE"
        echo "$I2C_PARAM" >> "$CONFIG_FILE"
        log_info "I2C parameter added to config.txt."
        
        REBOOT_REQUIRED=1
    fi
else
    log_warn "/boot/config.txt not found! You may need to enable I2C manually."
fi

# 5. Enable and Start Service
log_info "Enabling system service..."
/etc/init.d/argon_daemon enable

# Only start if I2C was already active, otherwise wait for reboot
if [ "${REBOOT_REQUIRED:-0}" -eq 0 ]; then
    /etc/init.d/argon_daemon restart
    log_info "Service started successfully."
else
    log_warn "Service enabled, but I2C requires a reboot to function."
fi

echo "========================================================"
echo -e "${GREEN}   INSTALLATION COMPLETE!   ${NC}"
echo "========================================================"

if [ "${REBOOT_REQUIRED:-0}" -eq 1 ]; then
    echo -e "${YELLOW}IMPORTANT: A system reboot is required to activate I2C.${NC}"
    echo "Please run: reboot"
fi
