#!/bin/sh

# ==============================================================================
# Argon ONE V3 Fan Control Uninstall Script (OpenWrt / RPi 5)
# Author: ciwga
# ==============================================================================

# ------------------------------------------------------------------------------
# CONFIGURATION & COLORS
# ------------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# UNINSTALLATION PROCESS
# ------------------------------------------------------------------------------

echo "========================================================"
echo "   Argon ONE V3 Fan Control Uninstaller (OpenWrt)       "
echo "========================================================"

# 1. Check Root Privileges
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

# 2. Stop and Disable Service
if [ -f "/etc/init.d/argon_daemon" ]; then
    log_info "Stopping service and removing from startup..."
    /etc/init.d/argon_daemon stop >/dev/null 2>&1
    /etc/init.d/argon_daemon disable >/dev/null 2>&1
else
    log_warn "Service script not found, skipping this step."
fi

# 3. Delete Files
log_info "Cleaning up system files..."

if [ -f "/usr/bin/argon_fan_control.sh" ]; then
    rm -f /usr/bin/argon_fan_control.sh
    log_info "/usr/bin/argon_fan_control.sh successfully deleted."
fi

if [ -f "/etc/init.d/argon_daemon" ]; then
    rm -f /etc/init.d/argon_daemon
    log_info "/etc/init.d/argon_daemon successfully deleted."
fi

# 4. Clean Lock Residues
if [ -d "/var/run/argon_fan.lock" ]; then
    rm -rf /var/run/argon_fan.lock
    log_info "Temporary lock files cleaned."
fi

# 5. Result and User Information
echo "========================================================"
echo -e "${GREEN}   UNINSTALLATION COMPLETE!   ${NC}"
echo "========================================================"
echo ""
log_warn "Important Note 1: The 'dtparam=i2c_arm=on' setting in '/boot/config.txt'"
log_warn "was NOT REMOVED to prevent breaking other hardware (HATs, sensors)."
log_warn "If you no longer need I2C at all, you can edit the file and remove the line manually."
echo ""
log_warn "Important Note 2: The installed 'i2c-tools' package was left on the system."
log_warn "If you want to remove the package from the system as well, run: opkg remove i2c-tools"
echo ""
