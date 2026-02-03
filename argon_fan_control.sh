#!/bin/sh

# ==============================================================================
# FILE: /usr/bin/argon_fan_control.sh
# DESCRIPTION: Argon ONE V3 Fan Control Daemon (OpenWrt / RPi 5)
# AUTHOR: ciwga
# DATE: 2026-02-03
# VERSION: 1.0.0
#
# LICENSE: MIT / GPLv3
# PLATFORM: OpenWrt (Ash Shell), Raspberry Pi 5
# DEPENDENCIES: i2c-tools
#
# USAGE:
#   This script is intended to be run by 'procd' as a foreground service.
#   Ensure the 'i2c_arm=on' parameter is set in /boot/config.txt.
# ==============================================================================

# ------------------------------------------------------------------------------
# SAFETY & ENVIRONMENT
# ------------------------------------------------------------------------------
# -u: Treat unset variables as an error when substituting.
set -u

# Ensure standard locale for string processing (awk, grep stability)
export LC_ALL=C

# ------------------------------------------------------------------------------
# CONFIGURATION CONSTANTS (Read-Only)
# ------------------------------------------------------------------------------
readonly CHIP_ADDR="0x1a"
readonly LOCK_DIR="/var/run/argon_fan.lock"
readonly PID_FILE="${LOCK_DIR}/pid"

# Timing (Seconds)
readonly POLL_INTERVAL=5
readonly HEARTBEAT_INTERVAL=60

# Hysteresis (Degrees Celsius)
# Safety margin to prevent fan hunting (rapid on/off cycling).
readonly HYST=4

# Fan Speeds (Argon Protocol: 0-100 Hexadecimal)
# RPi 5 runs hotter; thresholds are tuned for active cooling.
readonly SPEED_OFF="0x00"
readonly SPEED_QUIET="0x0A"  # 10%  - Silent
readonly SPEED_LOW="0x19"    # 25%  - Light Load
readonly SPEED_MED="0x37"    # 55%  - Medium Load (Safe Mode)
readonly SPEED_HIGH="0x64"   # 100% - Full Load (Emergency)

# Temperature Thresholds (Celsius)
readonly THRESH_HIGH=60
readonly THRESH_MED=55
readonly THRESH_LOW=45
readonly THRESH_QUIET=40

# ------------------------------------------------------------------------------
# STATE VARIABLES (Mutable)
# ------------------------------------------------------------------------------
SENSOR_ERR_STATE=0
I2C_ERR_STATE=0
CURRENT_LEVEL=0
LAST_WRITE_TIME=$SECONDS
DETECTED_BUS=""
THERMAL_ZONE_PATH=""

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Function: log_info
# Description: Logs informational messages to the system log (syslog).
# Arguments:
#   $1: Message string
log_info() { 
    logger -t argon_daemon -p daemon.notice "[INFO] $1"
}

# Function: log_err
# Description: Logs error messages to the system log (syslog) with high priority.
# Arguments:
#   $1: Message string
log_err() { 
    logger -t argon_daemon -p daemon.err "[ERROR] $1"
}

# Function: check_root
# Description: Ensures the script is running with root privileges.
# Returns: Exits with status 1 if not root.
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] This script must be run as root." >&2
        exit 1
    fi
}

# Function: check_dependencies
# Description: Verifies that required binaries (i2c-tools) are installed.
# Returns: Exits with status 1 if dependencies are missing.
check_dependencies() {
    local missing=0
    if ! command -v i2cdetect >/dev/null 2>&1; then
        log_err "Missing Dependency: 'i2cdetect' not found. (Run: opkg install i2c-tools)"
        missing=1
    fi
    if ! command -v i2cset >/dev/null 2>&1; then
        log_err "Missing Dependency: 'i2cset' not found. (Run: opkg install i2c-tools)"
        missing=1
    fi

    if [ "$missing" -eq 1 ]; then
        exit 1
    fi
}

# Function: acquire_lock
# Description: Implements an atomic locking mechanism using mkdir.
#              Prevents multiple instances of the daemon.
# Returns: 0 on success, exits on failure.
acquire_lock() {
    # 'mkdir' is atomic on POSIX filesystems.
    if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
        echo $$ > "$PID_FILE"
        return 0
    else
        # Lock exists, check for stale PID
        if [ -f "$PID_FILE" ]; then
            # 'read -r' is safe for raw input
            read -r OLD_PID < "$PID_FILE" 2>/dev/null || OLD_PID=""
            
            # Check if process is actually running via /proc
            if [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ]; then
                log_err "Service is already running (PID: $OLD_PID). Exiting."
                exit 1
            else
                log_info "Stale lock detected. Cleaning up..."
                rm -f "$PID_FILE"
                rmdir "$LOCK_DIR"
                
                # Retry lock acquisition
                if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
                    echo $$ > "$PID_FILE"
                    return 0
                fi
            fi
        fi
        log_err "Could not acquire lock. Check permissions for /var/run."
        exit 1
    fi
}

# Function: find_thermal_source
# Description: Scans sysfs to identify the correct thermal zone for the CPU/SoC.
# Returns: 0 if found (prints path), 1 if not found.
find_thermal_source() {
    local zone
    local type_val
    local found_path=""

    # Scan thermal zones
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -e "$zone/type" ] || continue
        
        read -r type_val < "$zone/type" 2>/dev/null || continue
        
        # Match common RPi and Linux thermal types
        case "$type_val" in
            "cpu-thermal"|"soc-thermal"|"x86_pkg_temp"|"bcm2835_thermal")
                found_path="$zone/temp"
                log_info "Thermal Sensor Detected: $type_val -> $found_path"
                break
                ;;
        esac
    done

    # Fallback for RPi 5 if no specific label matches
    if [ -z "$found_path" ]; then
        if [ -f "/sys/class/thermal/thermal_zone0/temp" ]; then
            log_info "WARNING: Specific thermal label not found, defaulting to 'thermal_zone0'."
            found_path="/sys/class/thermal/thermal_zone0/temp"
        else
            return 1
        fi
    fi
    
    echo "$found_path"
    return 0
}

# Function: find_i2c_bus
# Description: Scans I2C buses to find the Argon ONE chip (Address 0x1a).
# Returns: 0 if found (prints bus number), 1 if not found.
find_i2c_bus() {
    local dev
    local bus_num
    local found
    
    for dev in /dev/i2c-*; do
        [ -e "$dev" ] || continue
        # Extract bus number from filename (e.g., /dev/i2c-1 -> 1)
        bus_num="${dev##*-}"
        
        # Check for device 0x1a or UU (kernel driver occupied) on the bus
        found=$(i2cdetect -y -r "$bus_num" 2>/dev/null | awk '
            BEGIN { found=0 }
            {
                for(i=2; i<=NF; i++) {
                    if($i == "1a" || $i == "UU") { found=1; exit }
                }
            }
            END { print found }
        ')
        
        if [ "$found" -eq 1 ]; then
            echo "$bus_num"
            return 0
        fi
    done
    return 1
}

# Function: i2c_write
# Description: Writes a value to the I2C register with error handling.
# Arguments:
#   $1: Bus number
#   $2: Register address
#   $3: Value (Hex)
# Returns: 0 on success, 1 on failure.
i2c_write() {
    local bus="$1"
    local reg="$2"
    local val="$3"
    
    # Suppress output, capture exit code
    if ! i2cset -y -f "$bus" "$CHIP_ADDR" "$reg" "$val" >/dev/null 2>&1; then
        # Log error only once to prevent log flooding
        if [ "$I2C_ERR_STATE" -eq 0 ]; then
            log_err "I2C Communication Error! Bus: $bus, Reg: $reg, Val: $val"
            I2C_ERR_STATE=1
        fi
        return 1
    else
        # Recovery detection
        if [ "$I2C_ERR_STATE" -eq 1 ]; then
            log_info "I2C connection restored."
            I2C_ERR_STATE=0
        fi
        return 0
    fi
}

# Function: cleanup
# Description: Signal handler for graceful shutdown. Sets fan to safe speed.
cleanup() {
    log_info "Shutdown signal received (SIGTERM/SIGINT)..."
    
    # Check if bus was detected before trying to write
    if [ -n "${DETECTED_BUS:-}" ]; then
        # Set fan to Medium speed (safe fail-safe) on exit
        i2c_write "$DETECTED_BUS" "0x01" "$SPEED_MED"
    fi
    
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    log_info "Service stopped successfully."
    exit 0
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION FLOW
# ------------------------------------------------------------------------------

# Register signal handlers for procd compatibility
trap cleanup EXIT TERM INT HUP

check_root
check_dependencies
acquire_lock

log_info "Starting Argon ONE v3 Daemon (Platform: OpenWrt/RPi5)..."

# 1. Initialize Sensors
THERMAL_ZONE_PATH=$(find_thermal_source)
if [ -z "$THERMAL_ZONE_PATH" ]; then
    log_err "CRITICAL: No valid temperature sensor found! Check kernel modules."
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    exit 1
fi

# 2. Initialize I2C
DETECTED_BUS=$(find_i2c_bus)
if [ -z "$DETECTED_BUS" ]; then
    log_err "CRITICAL: Argon One (0x1a) not found on I2C bus! (Check config.txt: dtparam=i2c_arm=on)"
    rm -f "$PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null
    exit 1
fi

log_info "Configuration Successful: Bus=/dev/i2c-$DETECTED_BUS | Sensor=$THERMAL_ZONE_PATH"

# 3. Kickstart Fan
# Mode setting (0x03) varies by firmware revision, kept for safety.
i2c_write "$DETECTED_BUS" "0x03" "0x01"
# Spin up to full speed briefly to overcome static friction
i2c_write "$DETECTED_BUS" "0x01" "$SPEED_HIGH"
sleep 1
i2c_write "$DETECTED_BUS" "0x01" "$SPEED_OFF"

log_info "Entering Main Control Loop. Interval: ${POLL_INTERVAL}s"

# 4. Main Loop
while true; do
    # A. Read Temperature
    if read -r RAW_TEMP < "$THERMAL_ZONE_PATH" 2>/dev/null; then
        : # No-op, successful read
    else
        RAW_TEMP="-1"
    fi

    # B. Validate Reading
    if [ -z "$RAW_TEMP" ] || [ "$RAW_TEMP" -lt 0 ]; then
         TEMP=65 # Safe fallback temp
         if [ "$SENSOR_ERR_STATE" -eq 0 ]; then 
            log_err "Sensor Read Error! Activating Safe Mode (Assuming Temp=65)."
            SENSOR_ERR_STATE=1
         fi
    else
         # Integer division (ash shell standard)
         TEMP=$((RAW_TEMP / 1000))
         
         if [ "$SENSOR_ERR_STATE" -eq 1 ]; then
            log_info "Sensor reading restored. Current: ${TEMP}C"
            SENSOR_ERR_STATE=0
         fi
    fi

    # C. Determine Target Fan Level
    if   [ "$TEMP" -ge "$THRESH_HIGH" ];  then TARGET=4
    elif [ "$TEMP" -ge "$THRESH_MED" ];   then TARGET=3
    elif [ "$TEMP" -ge "$THRESH_LOW" ];   then TARGET=2
    elif [ "$TEMP" -ge "$THRESH_QUIET" ]; then TARGET=1
    else TARGET=0; fi

    # D. Apply Hysteresis (Prevent Rapid Cycling)
    if [ "$TARGET" -gt "$CURRENT_LEVEL" ]; then
        # If temp is rising, increase speed immediately (Active Cooling Priority)
        NEW_LEVEL=$TARGET
    elif [ "$TARGET" -lt "$CURRENT_LEVEL" ]; then
        # If temp is falling, apply hysteresis window
        case "$CURRENT_LEVEL" in
            4) BASE=$THRESH_HIGH ;;
            3) BASE=$THRESH_MED ;;
            2) BASE=$THRESH_LOW ;;
            1) BASE=$THRESH_QUIET ;;
            *) BASE=0 ;;
        esac
        
        # Only drop speed if temp is significantly below threshold (BASE - HYST)
        if [ "$TEMP" -le $((BASE - HYST)) ]; then
             NEW_LEVEL=$TARGET
        else
             NEW_LEVEL=$CURRENT_LEVEL
        fi
    else
        NEW_LEVEL=$CURRENT_LEVEL
    fi

    # E. Actuate Fan & Heartbeat
    TIME_DIFF=$((SECONDS - LAST_WRITE_TIME))
    
    # Write if level changed OR heartbeat interval elapsed
    if [ "$NEW_LEVEL" -ne "$CURRENT_LEVEL" ] || [ "$TIME_DIFF" -ge "$HEARTBEAT_INTERVAL" ]; then
        case "$NEW_LEVEL" in
            4) HEX="$SPEED_HIGH" ;;
            3) HEX="$SPEED_MED" ;;
            2) HEX="$SPEED_LOW" ;;
            1) HEX="$SPEED_QUIET" ;;
            *) HEX="$SPEED_OFF" ;;
        esac

        if i2c_write "$DETECTED_BUS" "0x01" "$HEX"; then
            if [ "$NEW_LEVEL" -ne "$CURRENT_LEVEL" ]; then
                log_info "State Changed: ${TEMP}C -> Fan Level: $NEW_LEVEL ($HEX)"
            fi
            CURRENT_LEVEL=$NEW_LEVEL
            LAST_WRITE_TIME=$SECONDS
        fi
    fi

    # F. Wait for next cycle
    sleep "$POLL_INTERVAL"
done
