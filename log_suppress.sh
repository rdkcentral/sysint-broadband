#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2016 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################
# Log Suppression Script for Non-RDK Logger Components
# This script analyzes log files and suppresses repeated log patterns
# to reduce log size before upload
#
# Suppression is ONLY applied to non-RDK logger component files.
# Files that log through rdk_logger are excluded from suppression.
#
# Usage: log_suppress.sh <input_directory> [output_directory]
# If output_directory is not provided, files are suppressed in-place
#
# Configuration:
#   Enable/Disable: TR-181 Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.Enable
#                   or syscfg RDKLogSuppressorEnable (fallback)
#   Pattern Length: TR-181 Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.MaxPatternLength
#                   or syscfg RDKLogSuppressorMaxPatternLength (fallback)
#   Default values: Enable=false, MaxPatternLength=10
#
# Incremental suppression:
#   Offset files are stored alongside output as <filename>.offset
#   Each offset file contains the number of lines already processed.
#   On subsequent runs, only new lines (beyond the offset) are suppressed
#   and appended to the existing output file.
#   Offsets are cleared by uploadRDKBLogs.sh after successful upload.
##########################################################################

# Source echo_t function if available
if [ -f /lib/rdk/utils.sh ]; then
    . /lib/rdk/utils.sh
else
    # Fallback echo_t function (BusyBox compatible)
    echo_t() {
        echo "`date '+%y%m%d-%T'` $1"
    }
fi

# Source device.properties for device-specific settings
if [ -f /etc/device.properties ]; then
    . /etc/device.properties
fi

# Source logFiles.properties to get RDK logger file patterns
if [ -f /etc/logFiles.properties ]; then
    . /etc/logFiles.properties
fi

##########################################################################
# TR-181 and syscfg Configuration Functions
# TR-181 Path: Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor
# syscfg keys: RDKLogSuppressorEnable, RDKLogSuppressorMaxPatternLength
##########################################################################

# Get log suppression enable status from TR-181 or syscfg
# Returns: "true" if enabled, "false" if disabled
get_log_suppress_enable() {
    local enable_value=""
    
    # Try TR-181 first (dmcli)
    # Path: Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.Enable
    if [ -x /usr/bin/dmcli ]; then
        enable_value=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.Enable 2>/dev/null | grep "value:" | cut -d':' -f3 | tr -d ' ')
        if [ -n "$enable_value" ]; then
            echo_t "Log suppression enable from TR-181: $enable_value"
            echo "$enable_value"
            return
        fi
    fi
    
    # Fallback to syscfg (RDKLogSuppressorEnable)
    enable_value=$(syscfg get RDKLogSuppressorEnable 2>/dev/null)
    if [ -n "$enable_value" ]; then
        echo_t "Log suppression enable from syscfg: $enable_value"
        echo "$enable_value"
        return
    fi
    
    # Default: disabled (to be safe, require explicit enable)
    echo_t "Log suppression enable not configured, defaulting to false"
    echo "false"
}

# Get pattern length from TR-181 or syscfg
# Returns: integer value for max pattern length (default: 10)
get_pattern_length() {
    local pattern_len=""
    
    # Try TR-181 first (dmcli)
    # Path: Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.MaxPatternLength
    if [ -x /usr/bin/dmcli ]; then
        pattern_len=$(dmcli eRT retv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.RDKLogSuppressor.MaxPatternLength 2>/dev/null | grep "value:" | cut -d':' -f3 | tr -d ' ')
        if [ -n "$pattern_len" ] && echo "$pattern_len" | grep -qE '^[0-9]+$'; then
            echo_t "Pattern length from TR-181: $pattern_len"
            echo "$pattern_len"
            return
        fi
    fi
    
    # Fallback to syscfg (RDKLogSuppressorMaxPatternLength)
    pattern_len=$(syscfg get RDKLogSuppressorMaxPatternLength 2>/dev/null)
    if [ -n "$pattern_len" ] && echo "$pattern_len" | grep -qE '^[0-9]+$'; then
        echo_t "Pattern length from syscfg: $pattern_len"
        echo "$pattern_len"
        return
    fi
    
    # Default pattern length (matches utopia system_defaults)
    echo_t "Pattern length not configured, defaulting to 10"
    echo "10"
}

##########################################################################
# Check if suppression is enabled via TR-181 or syscfg
##########################################################################
LOG_SUPPRESS_ENABLED=$(get_log_suppress_enable)
if [ "$LOG_SUPPRESS_ENABLED" != "true" ]; then
    echo_t "Log suppression is disabled (TR-181/syscfg). Skipping."
    exit 0
fi

# Get pattern length configuration
MAX_PATTERN_LENGTH=$(get_pattern_length)
echo_t "Using pattern length: $MAX_PATTERN_LENGTH"

LOG_SUPPRESS_INPUT_DIR="$1"
LOG_SUPPRESS_OUTPUT_DIR="$2"

# If output directory not provided, use input directory (in-place)
if [ -z "$LOG_SUPPRESS_OUTPUT_DIR" ]; then
    LOG_SUPPRESS_OUTPUT_DIR="$LOG_SUPPRESS_INPUT_DIR"
    LOG_SUPPRESS_IN_PLACE=1
else
    LOG_SUPPRESS_IN_PLACE=0
fi

# Check if input directory is provided
if [ -z "$LOG_SUPPRESS_INPUT_DIR" ]; then
    echo_t "Usage: $0 <input_directory> [output_directory]"
    exit 1
fi

if [ ! -d "$LOG_SUPPRESS_INPUT_DIR" ]; then
    echo_t "Error: Input directory '$LOG_SUPPRESS_INPUT_DIR' not found"
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$LOG_SUPPRESS_OUTPUT_DIR"

# Directory to store offset files (tracks how many lines were already processed per file)
# Store in /nvram2 directly, not inside /nvram2/logs, so offsets survive log cleanup
OFFSET_DIR="/nvram2/.log_suppress_offsets"
mkdir -p "$OFFSET_DIR"

##########################################################################
# RDK Logger Component File Detection
# Files that log through rdk_logger should NOT be suppressed
# Sources (checked in order):
#   1. /etc/log4crc XML - authoritative source of rdk_logger appenders
#   2. /etc/logFiles.properties (LOG_FILES_NAMES variable)
#   3. ARM_FILE_LIST / ATOM_FILE_LIST variables
##########################################################################

# Cache for RDK logger prefixes (populated once, reused per file check)
RDK_LOGGER_PREFIXES=""

# Extract RDK logger file prefixes from log4crc XML and logFiles.properties
# Builds a space-separated list of file prefixes (e.g., "TR69log.txt PAMlog.txt ...")
build_rdk_logger_prefix_cache() {
    local prefixes=""

    # Source 1: Parse /etc/log4crc for appender prefix= attributes
    # This is the authoritative source — lists all rdk_logger file destinations
    if [ -f /etc/log4crc ]; then
        local log4crc_prefixes
        log4crc_prefixes=$(grep -o 'prefix="[^"]*"' /etc/log4crc 2>/dev/null | sed 's/prefix="//;s/"//' | sort -u)
        if [ -n "$log4crc_prefixes" ]; then
            prefixes="$log4crc_prefixes"
        fi
    fi

    # Source 2: LOG_FILES_NAMES from /etc/logFiles.properties
    if [ -n "$LOG_FILES_NAMES" ]; then
        for pattern in $LOG_FILES_NAMES; do
            # Strip wildcard suffix: "TR69log.txt.*" -> "TR69log.txt"
            local clean=$(echo "$pattern" | sed 's/\.\*$//' | sed 's/\*$//')
            [ -n "$clean" ] && prefixes="$prefixes $clean"
        done
    fi

    # Source 3: ARM_FILE_LIST and ATOM_FILE_LIST
    local all_file_lists="$ARM_FILE_LIST $ATOM_FILE_LIST"
    for pattern in $all_file_lists; do
        pattern=$(echo "$pattern" | tr '{},' ' ')
        for p in $pattern; do
            local clean=$(echo "$p" | sed 's/\.\*$//' | sed 's/\*$//' | sed 's/\.[0-9]*$//')
            [ -n "$clean" ] && prefixes="$prefixes $clean"
        done
    done

    # Deduplicate
    RDK_LOGGER_PREFIXES=$(echo "$prefixes" | tr ' ' '\n' | sort -u | tr '\n' ' ')
}

# Check if a file is an RDK logger component file
# Returns 0 (true) if it's an RDK logger file, 1 (false) otherwise
is_rdk_logger_file() {
    local filename="$1"
    local basename_file=$(basename "$filename")

    # Build cache on first call
    if [ -z "$RDK_LOGGER_PREFIXES" ]; then
        build_rdk_logger_prefix_cache
    fi

    # No patterns found — can't identify RDK files, allow suppression
    if [ -z "$RDK_LOGGER_PREFIXES" ]; then
        return 1
    fi

    # Check if filename matches any known RDK logger prefix
    for prefix in $RDK_LOGGER_PREFIXES; do
        case "$basename_file" in
            ${prefix}|${prefix}.[0-9]*|${prefix}[0-9]*)
                return 0  # Is an RDK logger file - SKIP suppression
                ;;
        esac
    done

    return 1  # Not an RDK logger file - ALLOW suppression
}

# ------------------------------------------------------------
# get_offset <offset_file>
#   Reads the stored line offset for a given file.
#   Returns 0 if no offset exists yet (first run).
# ------------------------------------------------------------
get_offset() {
    local offset_file="$1"
    if [ -f "$offset_file" ]; then
        cat "$offset_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# ------------------------------------------------------------
# set_offset <offset_file> <value>
#   Persists the current processed line count for a file.
# ------------------------------------------------------------
set_offset() {
    local offset_file="$1"
    local value="$2"
    echo "$value" > "$offset_file"
}

# ------------------------------------------------------------
# Per-Process CPU Overhead Monitoring Functions
# ------------------------------------------------------------

# Log file for CPU overhead reports
CPU_OVERHEAD_LOG="/rdklogs/logs/log_suppress_cpu_overhead.txt"

# Dedicated log file for suppression statistics
LOG_SUPPRESS_STATS_LOG="/rdklogs/logs/log_suppress_stats.txt"

# Log function that writes to both stdout and dedicated log file
log_cpu_overhead() {
    local msg="$1"
    echo_t "$msg"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $msg" >> "$CPU_OVERHEAD_LOG" 2>/dev/null
}

# Log function for suppression statistics - writes to dedicated stats file
log_suppress_stats() {
    local msg="$1"
    echo_t "$msg"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $msg" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
}

# Log size tracking entry
log_size_tracking() {
    local stage="$1"
    local dir="$2"
    local size_kb="$3"
    local timestamp=`date '+%Y-%m-%d %H:%M:%S'`
    
    # Log to stats file
    echo "[$timestamp] SIZE_TRACK [$stage] $dir Size=${size_kb}KB" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
    echo_t "SIZE_TRACK [${stage}]: ${dir} = ${size_kb} KB"
}

# Get process CPU time from /proc/PID/stat (utime + stime in jiffies)
# Works on all Linux including BusyBox
get_proc_cpu_time() {
    local pid="${1:-self}"
    if [ -f "/proc/$pid/stat" ]; then
        awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Get system uptime in jiffies (centiseconds)
get_system_uptime_jiffies() {
    if [ -f /proc/uptime ]; then
        # /proc/uptime gives seconds with decimals, convert to centiseconds (jiffies at 100Hz)
        awk '{printf "%.0f", $1 * 100}' /proc/uptime 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Get process memory usage in KB from /proc/PID/status
# Works on all Linux including BusyBox
get_process_mem_kb() {
    local pid="$1"
    local mem_kb=0
    
    if [ -n "$pid" ] && [ -f "/proc/$pid/status" ]; then
        # VmRSS is the resident set size (actual memory used)
        mem_kb=$(grep -i "^VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        [ -z "$mem_kb" ] && mem_kb=0
        echo "$mem_kb" | grep -qE '^[0-9]+$' || mem_kb=0
    fi
    echo "$mem_kb"
}

# Get total system memory in KB
get_total_mem_kb() {
    local total_kb=0
    if [ -f /proc/meminfo ]; then
        total_kb=$(grep -i "^MemTotal:" /proc/meminfo 2>/dev/null | awk '{print $2}')
        [ -z "$total_kb" ] && total_kb=1
    fi
    echo "$total_kb"
}

# Get process memory usage as percentage
get_process_mem_usage() {
    local pid="$1"
    local mem_pct=0
    local proc_mem=$(get_process_mem_kb "$pid")
    local total_mem=$(get_total_mem_kb)
    
    if [ "$total_mem" -gt 0 ] 2>/dev/null && [ "$proc_mem" -gt 0 ] 2>/dev/null; then
        mem_pct=$((proc_mem * 100 / total_mem))
    fi
    echo "$mem_pct"
}

# Get process command name from /proc/PID/comm or /proc/PID/cmdline
# Works on all Linux including BusyBox
get_process_cmd() {
    local pid="$1"
    local cmd=""
    
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        # Try /proc/PID/comm first (cleaner, single word)
        if [ -f "/proc/$pid/comm" ]; then
            cmd=$(cat "/proc/$pid/comm" 2>/dev/null | tr -d '\n')
        fi
        # Fallback to cmdline if comm is empty
        if [ -z "$cmd" ] && [ -f "/proc/$pid/cmdline" ]; then
            cmd=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | awk '{print $1}')
            cmd=$(basename "$cmd" 2>/dev/null)
        fi
        [ -z "$cmd" ] && cmd="sh"
    fi
    echo "$cmd"
}

# Initialize per-process CPU monitoring
init_cpu_monitor() {
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║  PER-PROCESS CPU MONITORING STARTED                        ║"
    log_cpu_overhead "╚════════════════════════════════════════════════════════════╝"
    
    CPU_MON_START_SEC=$(date +%s)
    CPU_MON_START_PROC=$(get_proc_cpu_time $$)
    CPU_MON_START_UPTIME=$(get_system_uptime_jiffies)
    CPU_MON_PID=$$
    CPU_MON_SAMPLES=0
    CPU_MON_SUM=0
    CPU_MON_PEAK=0
    CPU_MON_MEM_PEAK=0
    CPU_MON_LAST_PROC=$(get_proc_cpu_time $$)
    CPU_MON_LAST_UPTIME=$(get_system_uptime_jiffies)
    
    # Initial snapshot
    local init_mem_kb=$(get_process_mem_kb $CPU_MON_PID)
    local init_mem_pct=$(get_process_mem_usage $CPU_MON_PID)
    local proc_cmd=$(get_process_cmd $CPU_MON_PID)
    
    log_cpu_overhead "[INIT] PID: $CPU_MON_PID ($proc_cmd) | Initial Mem: ${init_mem_kb}KB (${init_mem_pct}%)"
}

# Sample per-process CPU during execution using /proc filesystem
# Calculates instantaneous CPU% based on jiffies delta since last sample
sample_cpu() {
    local current_proc=$(get_proc_cpu_time $CPU_MON_PID)
    local current_uptime=$(get_system_uptime_jiffies)
    
    # Calculate delta since last sample
    local proc_delta=$((current_proc - CPU_MON_LAST_PROC))
    local uptime_delta=$((current_uptime - CPU_MON_LAST_UPTIME))
    
    # Calculate instantaneous CPU% (process jiffies / elapsed jiffies * 100)
    local cpu_pct=0
    if [ "$uptime_delta" -gt 0 ] 2>/dev/null; then
        cpu_pct=$((proc_delta * 100 / uptime_delta))
    fi
    
    # Get current memory
    local mem_kb=$(get_process_mem_kb $CPU_MON_PID)
    local mem_pct=$(get_process_mem_usage $CPU_MON_PID)
    
    # Update tracking
    CPU_MON_SUM=$((CPU_MON_SUM + cpu_pct))
    CPU_MON_SAMPLES=$((CPU_MON_SAMPLES + 1))
    [ "$cpu_pct" -gt "$CPU_MON_PEAK" ] && CPU_MON_PEAK=$cpu_pct
    [ "$mem_kb" -gt "$CPU_MON_MEM_PEAK" ] && CPU_MON_MEM_PEAK=$mem_kb
    
    # Update last values for next sample
    CPU_MON_LAST_PROC=$current_proc
    CPU_MON_LAST_UPTIME=$current_uptime
}

# Report per-process CPU overhead statistics
report_cpu_overhead() {
    local end_sec=$(date +%s)
    local end_proc=$(get_proc_cpu_time $$)
    local end_uptime=$(get_system_uptime_jiffies)
    
    # Elapsed wall-clock time
    local elapsed=$((end_sec - CPU_MON_START_SEC))
    [ "$elapsed" -eq 0 ] && elapsed=1
    
    # Process-specific CPU time (jiffies to ms, assuming 100Hz)
    local proc_jiffies=$((end_proc - CPU_MON_START_PROC))
    local proc_ms=$((proc_jiffies * 10))
    
    # Calculate CPU overhead percentage using jiffies delta
    # This is more accurate: (process_jiffies / elapsed_jiffies) * 100
    local uptime_jiffies=$((end_uptime - CPU_MON_START_UPTIME))
    local cpu_overhead_pct=0
    if [ "$uptime_jiffies" -gt 0 ] 2>/dev/null; then
        cpu_overhead_pct=$((proc_jiffies * 100 / uptime_jiffies))
    fi
    
    # Average CPU from samples
    local avg_cpu=0
    if [ "$CPU_MON_SAMPLES" -gt 0 ]; then
        avg_cpu=$((CPU_MON_SUM / CPU_MON_SAMPLES))
    fi
    
    # Final memory snapshot
    local final_mem_kb=$(get_process_mem_kb $CPU_MON_PID)
    local final_mem_pct=$(get_process_mem_usage $CPU_MON_PID)
    local peak_mem_pct=0
    local total_mem=$(get_total_mem_kb)
    if [ "$total_mem" -gt 0 ] 2>/dev/null && [ "$CPU_MON_MEM_PEAK" -gt 0 ] 2>/dev/null; then
        peak_mem_pct=$((CPU_MON_MEM_PEAK * 100 / total_mem))
    fi
    
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║       LOG SUPPRESSION PER-PROCESS CPU OVERHEAD REPORT              ║"
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PROCESS IDENTIFICATION:                                           "
    log_cpu_overhead "║    PID: $CPU_MON_PID                                               "
    log_cpu_overhead "║    Command: $(get_process_cmd $CPU_MON_PID)                        "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  CONFIGURATION:                                                    "
    log_cpu_overhead "║    Log Suppression Enabled: $LOG_SUPPRESS_ENABLED                  "
    log_cpu_overhead "║    Pattern Length: $MAX_PATTERN_LENGTH                             "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  TIMING:                                                           "
    log_cpu_overhead "║    Duration: ${elapsed} seconds                                    "
    log_cpu_overhead "║    Process CPU time: ${proc_ms} ms (${proc_jiffies} jiffies)       "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PER-PROCESS CPU USAGE:                                            "
    log_cpu_overhead "║    CPU Overhead: ${cpu_overhead_pct}%                              "
    log_cpu_overhead "║    Peak CPU (sampled): ${CPU_MON_PEAK}%                            "
    log_cpu_overhead "║    Average CPU (sampled): ${avg_cpu}%                              "
    log_cpu_overhead "║    Samples collected: ${CPU_MON_SAMPLES}                           "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PER-PROCESS MEMORY USAGE:                                         "
    log_cpu_overhead "║    Peak Memory: ${CPU_MON_MEM_PEAK} KB (${peak_mem_pct}%)          "
    log_cpu_overhead "║    Final Memory: ${final_mem_kb} KB (${final_mem_pct}%)            "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    
    # Overhead assessment based on per-process readings
    if [ "$cpu_overhead_pct" -gt 30 ] || [ "$CPU_MON_PEAK" -gt 50 ]; then
        log_cpu_overhead "║  ⚠ WARNING: Significant process CPU overhead detected!            "
        log_cpu_overhead "║    Recommendation: Consider running with 'nice -n 19'             "
    elif [ "$cpu_overhead_pct" -gt 15 ] || [ "$CPU_MON_PEAK" -gt 25 ]; then
        log_cpu_overhead "║  ⚡ MODERATE: Some process CPU overhead observed                   "
    else
        log_cpu_overhead "║  ✓ LOW: Minimal process CPU impact                                 "
    fi
    
    log_cpu_overhead "╚════════════════════════════════════════════════════════════════════╝"
    log_cpu_overhead "Logs saved to: $CPU_OVERHEAD_LOG"
}

# Function to suppress logs in a single file (or a stream of new lines)
# Arguments:
#   INPUT_FILE  - path to read new lines from (may be a temp slice file)
#   OUTPUT_FILE - path to write suppressed output (append mode when incremental)
#   APPEND_MODE - 1 = append to OUTPUT_FILE, 0 = overwrite
#   PATTERN_LEN - maximum pattern length to detect (from TR-181/syscfg)
suppress_log_file() {
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local APPEND_MODE="${3:-0}"
    local PATTERN_LEN="${4:-$MAX_PATTERN_LENGTH}"
    local TEMP_FILE="${OUTPUT_FILE}.suppress.tmp"

    # =========================================================================
    # Pattern suppression with timing classification (burst/periodic/sporadic)
    # Aligns with rdk_logger feature/RDKB-log-suppressor dynamic classification
    # =========================================================================
    awk -v max_pattern_len="$PATTERN_LEN" '
# ----------------------------------------------------------------------------
# extract_time_hms: pull HH:MM:SS from a timestamp string
# ----------------------------------------------------------------------------
function extract_time_hms(ts) {
    if (match(ts, /[0-9]{2}:[0-9]{2}:[0-9]{2}/)) return substr(ts, RSTART, RLENGTH)
    return ts
}

# ----------------------------------------------------------------------------
# extract_time_with_usec: pull HH:MM:SS.uuuuuu (or HH:MM:SS) from timestamp
# Phase 1 uses microsecond precision in sporadic At: lines
# ----------------------------------------------------------------------------
function extract_time_with_usec(ts) {
    if (match(ts, /[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+/))
        return substr(ts, RSTART, RLENGTH)
    if (match(ts, /[0-9]{2}:[0-9]{2}:[0-9]{2}/))
        return substr(ts, RSTART, RLENGTH)
    return ts
}

# ----------------------------------------------------------------------------
# month_to_num: convert 3-letter month abbreviation to 2-digit number
# ----------------------------------------------------------------------------
function month_to_num(mn) {
    if (mn == "Jan") return "01"; if (mn == "Feb") return "02"
    if (mn == "Mar") return "03"; if (mn == "Apr") return "04"
    if (mn == "May") return "05"; if (mn == "Jun") return "06"
    if (mn == "Jul") return "07"; if (mn == "Aug") return "08"
    if (mn == "Sep") return "09"; if (mn == "Oct") return "10"
    if (mn == "Nov") return "11"; if (mn == "Dec") return "12"
    return "00"
}

# ----------------------------------------------------------------------------
# extract_date_mmdd: pull MM-DD date from a timestamp string
# Phase 1 uses [MM-DD] brackets in sporadic At: lines when date changes
# ----------------------------------------------------------------------------
function extract_date_mmdd(ts,    m, d, mn) {
    if (match(ts, /^[0-9]{6}-[0-9]{2}:/)) {
        m = substr(ts, 3, 2); d = substr(ts, 5, 2); return m "-" d
    }
    if (match(ts, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
        m = substr(ts, RSTART+5, 2); d = substr(ts, RSTART+8, 2); return m "-" d
    }
    if (match(ts, /[0-9]{4}\.[0-9]{2}\.[0-9]{2}/)) {
        m = substr(ts, RSTART+5, 2); d = substr(ts, RSTART+8, 2); return m "-" d
    }
    if (match(ts, /^[0-9]{8} /)) {
        m = substr(ts, 5, 2); d = substr(ts, 7, 2); return m "-" d
    }
    if (match(ts, /^[0-9]{4} [A-Za-z]{3} [0-9]{2}/)) {
        mn = substr(ts, 6, 3); d = substr(ts, 10, 2)
        return month_to_num(mn) "-" d
    }
    if (match(ts, /[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        mn = substr(ts, RSTART, 3)
        if (month_to_num(mn) != "00") {
            d = substr(ts, RSTART+4, 2); return month_to_num(mn) "-" d
        }
    }
    if (match(ts, /[0-9]{2}\/[0-9]{2}\/[0-9]{4}/)) {
        d = substr(ts, RSTART, 2); m = substr(ts, RSTART+3, 2); return m "-" d
    }
    return ""
}

# ----------------------------------------------------------------------------
# timestamp_to_seconds: convert HH:MM:SS portion to total seconds
# ----------------------------------------------------------------------------
function timestamp_to_seconds(ts,    h, m, s, parts, time_part) {
    if (match(ts, /[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        time_part = substr(ts, RSTART, RLENGTH)
        split(time_part, parts, ":")
        h = int(parts[1]); m = int(parts[2]); s = int(parts[3])
        return h * 3600 + m * 60 + s
    }
    return -1
}

# ----------------------------------------------------------------------------
# classify_timing: burst / periodic / sporadic based on gap analysis
# Aligns with rdk_logger feature/RDKB-log-suppressor classification:
#   BURST:    min_gap < 0.1s (100ms) AND rate >= 10 msg/s, or all gaps are 0
#   PERIODIC: max_gap/min_gap < 3 (consistent gap intervals)
#   SPORADIC: default (variable/inconsistent gaps)
# ----------------------------------------------------------------------------
function classify_timing(gap_count, gaps_arr, total_duration,
                         min_gap, max_gap, avg_gap, rate, ratio, i) {
    if (gap_count <= 0) return "sporadic"

    # Calculate min/max/avg gap
    min_gap = gaps_arr[1]; max_gap = gaps_arr[1]; avg_gap = 0
    for (i = 1; i <= gap_count; i++) {
        if (gaps_arr[i] < min_gap) min_gap = gaps_arr[i]
        if (gaps_arr[i] > max_gap) max_gap = gaps_arr[i]
        avg_gap += gaps_arr[i]
    }
    avg_gap = avg_gap / gap_count

    # Calculate message rate (messages per second)
    rate = 0
    if (avg_gap > 0) rate = 1 / avg_gap
    else if (total_duration > 0) rate = (gap_count + 1) / total_duration
    else if (gap_count > 0) rate = gap_count + 1

    # BURST: all gaps are 0 (instantaneous), or min_gap < 100ms with high rate
    if (max_gap == 0 || (min_gap < 0.1 && rate >= 10))
        return "burst"

    # PERIODIC: gap ratio < 3 (consistent intervals) with at least 2 cycles
    if (min_gap > 0 && gap_count >= 2) {
        ratio = max_gap / min_gap
        if (ratio < 3) return "periodic"
    }

    # SPORADIC: default for variable/inconsistent gaps
    return "sporadic"
}

# ----------------------------------------------------------------------------
# build_timing_detail: build timing classification detail string
# Returns detail only (e.g., "~150 msg/s", "~every 5s", "over 10 min")
# Phase 1: behavior and detail are separate, combined as "behavior detail"
# ----------------------------------------------------------------------------
function build_timing_detail(timing_type, rate, avg_gap, total_duration, gap_count,    detail) {
    detail = ""
    if (timing_type == "burst") {
        if (rate > 0) detail = "~" int(rate) " msg/s"
    } else if (timing_type == "periodic") {
        if (avg_gap >= 60)       detail = "~every " int(avg_gap / 60) "min"
        else if (avg_gap >= 1)   detail = "~every " int(avg_gap) "s"
        else                     detail = "~every " int(avg_gap * 1000) "ms"
    } else {
        if (gap_count > 0) {
            if (total_duration >= 60) detail = "over " int(total_duration / 60) " min"
            else if (total_duration > 0) detail = "over " int(total_duration) "s"
        }
    }
    return detail
}

# ----------------------------------------------------------------------------
# build_sporadic_ts: build sporadic timestamp list with [MM-DD] date brackets
# Matches Phase 1 format: date bracket only emitted when date changes
# ----------------------------------------------------------------------------
function build_sporadic_ts(ts_arr, start_idx, end_idx,
                           ts_out, last_date, cur_date, cur_time, t) {
    ts_out = ""; last_date = ""
    for (t = start_idx; t <= end_idx; t++) {
        cur_date = extract_date_mmdd(ts_arr[t])
        cur_time = extract_time_with_usec(ts_arr[t])
        if (ts_out != "") ts_out = ts_out ", "
        if (cur_date != "" && cur_date != last_date) {
            ts_out = ts_out "[" cur_date "] " cur_time
            last_date = cur_date
        } else {
            ts_out = ts_out cur_time
        }
    }
    return ts_out
}

# ----------------------------------------------------------------------------
# strip_trailing_ws: remove trailing whitespace from a string
# Phase 1 strips trailing newlines from message for clean quoting
# ----------------------------------------------------------------------------
function strip_trailing_ws(s) {
    gsub(/[ \t\r\n]+$/, "", s)
    return s
}

BEGIN { idx = 0 }

{
    if (length($0) == 0 || $0 ~ /^[[:space:]]*$/) next
    idx++
    lines[idx] = $0
    timestamp = ""; message = ""

    # --- Timestamp format detection (14 formats supported) ---
    if      (match($0, /^[0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[0-9-]+-[0-9:.]+ /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[0-9]{4} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else if (match($0, /^\[[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\] /))
        { timestamp = substr($0,2,RLENGTH-2); message = substr($0,RLENGTH+2) }
    else if (match($0, /^[A-Za-z]+, [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}:/))
        { timestamp = substr($0,1,RLENGTH-1); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[0-9]{8} [0-9]{6}\.[0-9]{6} /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z]{3} [0-9]{4} /) ||
             match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    # OneWifi format: [OneWifi] YYMMDD-HH:MM:SS.microseconds<I/E>  message
    else if (match($0, /^\[OneWifi\] [0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}<[IE]>[ ]+/))
        { timestamp = substr($0,11,22); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /))
        { timestamp = substr($0,1,19); message = substr($0,21) }
    else if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{2}\/[0-9]{2}\/[0-9]{4})\] /))
        { timestamp = substr($0,2,RLENGTH-3); message = substr($0,RLENGTH+2) }
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*:/))
        { timestamp = substr($0,1,RLENGTH); message = substr($0,RLENGTH+1) }
    else
        { timestamp = ""; message = $0 }

    timestamps[idx] = timestamp
    content[idx]    = message
    gsub(/^[ \t]+/, "", content[idx])
}

END {
    i = 1
    while (i <= idx) {
        found = 0

        # ----------------------------------------------------------------
        # Lines WITHOUT timestamp: check for consecutive repetition
        # Phase 1 alignment: print 2 visible, suppress rest
        # ----------------------------------------------------------------
        if (timestamps[i] == "") {
            if (i < idx && content[i] == content[i+1] && timestamps[i+1] == "") {
                rep_count = 1
                j = i + 1
                while (j <= idx && content[i] == content[j] && timestamps[j] == "") {
                    rep_count++
                    j++
                }
                if (rep_count > 2) {
                    print lines[i]
                    print lines[i+1]
                    clean_msg = strip_trailing_ws(content[i])
                    print "[SUPPRESS] \"" clean_msg "\" repeated " (rep_count - 2) " times (no timestamp)"
                    i += rep_count
                    found = 1
                }
            }
            if (!found) {
                print lines[i]
                i++
            }
            continue
        }

        # ----------------------------------------------------------------
        # Single-line repetition check (with timestamps)
        # Phase 1 alignment: print 2 visible, suppress rest
        # Format: [SUPPRESS] "<message>" repeated N times (behavior detail, window)
        # ----------------------------------------------------------------
        if (i < idx && content[i] == content[i+1]) {
            rep_count = 1
            j = i + 1
            delete rep_timestamps; delete gaps
            rep_timestamps[1] = timestamps[i]; ts_count = 1
            while (j <= idx && content[i] == content[j] && timestamps[j] != "") {
                rep_count++; ts_count++
                rep_timestamps[ts_count] = timestamps[j]
                j++
            }
            if (rep_count > 2) {
                suppressed_count = rep_count - 2

                # Phase 1: time window from pattern detection (2nd) to last
                ts_first_hms = extract_time_hms(rep_timestamps[2])
                ts_last_hms  = extract_time_hms(rep_timestamps[ts_count])

                # Duration from 2nd occurrence to last
                first_sec = timestamp_to_seconds(rep_timestamps[2])
                last_sec  = timestamp_to_seconds(rep_timestamps[ts_count])
                total_duration = 0
                if (first_sec >= 0 && last_sec >= 0) {
                    total_duration = last_sec - first_sec
                    if (total_duration < 0) total_duration += 86400
                }

                # Gap analysis: from detection to each suppressed (matches Phase 1)
                gap_count = 0
                delete gaps
                for (g = 3; g <= ts_count; g++) {
                    prev_sec = timestamp_to_seconds(rep_timestamps[g-1])
                    curr_sec = timestamp_to_seconds(rep_timestamps[g])
                    if (prev_sec >= 0 && curr_sec >= 0) {
                        gap = curr_sec - prev_sec
                        if (gap < 0) gap += 86400
                        gap_count++; gaps[gap_count] = gap
                    }
                }

                timing_type = classify_timing(gap_count, gaps, total_duration)

                # Phase 1: reclassify as burst if high rate but no gap data
                rate = 0; avg_gap = 0
                if (gap_count > 0) {
                    sum_gaps = 0
                    for (g = 1; g <= gap_count; g++) sum_gaps += gaps[g]
                    avg_gap = sum_gaps / gap_count
                    if (avg_gap > 0) rate = 1 / avg_gap
                } else if (total_duration > 0) {
                    rate = suppressed_count / total_duration
                    if (timing_type == "sporadic" && rate > 10)
                        timing_type = "burst"
                }

                timing_detail = build_timing_detail(timing_type, rate, avg_gap, total_duration, gap_count)

                # Window string (seconds precision, matches Phase 1)
                if (ts_first_hms == ts_last_hms)
                    window_str = "at " ts_first_hms
                else
                    window_str = ts_first_hms "-" ts_last_hms

                # Phase 1 format: [SUPPRESS] "<message>" repeated N times
                clean_msg = strip_trailing_ws(content[i])
                behavior_str = timing_type
                if (timing_detail != "") behavior_str = behavior_str " " timing_detail

                # Print 2 visible lines (Phase 1: 2 cycles visible)
                print lines[i]
                print lines[i+1]
                print "[SUPPRESS] \"" clean_msg "\" repeated " suppressed_count " times (" behavior_str ", " window_str ")"

                # Sporadic timestamps with date brackets (Phase 1 format)
                if (timing_type == "sporadic" && ts_count > 2) {
                    ts_list = build_sporadic_ts(rep_timestamps, 3, ts_count)
                    if (ts_list != "") print "  At: " ts_list
                }

                i += rep_count; found = 1
            }
        }

        # ----------------------------------------------------------------
        # Multi-line pattern check (2 up to max_pattern_len lines)
        # Phase 1 alignment: print 2 full cycles, suppress rest
        # Format: [SUPPRESS] L-message pattern repeated N times (...)
        # ----------------------------------------------------------------
        if (!found) {
            local_max = max_pattern_len
            if (idx - i < local_max) local_max = idx - i
            for (plen = 2; plen <= local_max && !found; plen++) {
                if (i + plen > idx) continue
                rep_count = 1; can_continue = 1
                delete pattern_timestamps; delete gaps; pt_count = 0
                for (k = 0; k < plen; k++) {
                    pt_count++
                    pattern_timestamps[pt_count] = timestamps[i + k]
                }
                while (can_continue && i + plen * (rep_count + 1) - 1 <= idx) {
                    matches = 1
                    for (k = 0; k < plen; k++) {
                        if (content[i+k] != content[i + plen*rep_count + k] ||
                            timestamps[i + plen*rep_count + k] == "") {
                            matches = 0; break
                        }
                    }
                    if (matches) {
                        rep_count++
                        for (k = 0; k < plen; k++) {
                            pt_count++
                            pattern_timestamps[pt_count] = timestamps[i + plen*(rep_count-1) + k]
                        }
                    } else can_continue = 0
                }
                if (rep_count > 2) {
                    suppressed_count = rep_count - 2

                    # Print 2 visible cycles (Phase 1: 2 full cycles before suppression)
                    for (k = 0; k < plen * 2; k++) print lines[i + k]

                    # Time window: from 2nd cycle to last cycle
                    ts_start     = timestamps[i + plen]
                    ts_end       = timestamps[i + plen*(rep_count-1) + plen - 1]
                    ts_start_hms = extract_time_hms(ts_start)
                    ts_end_hms   = extract_time_hms(ts_end)

                    start_sec = timestamp_to_seconds(ts_start)
                    end_sec   = timestamp_to_seconds(ts_end)
                    total_duration = 0; gap_count = 0
                    delete gaps
                    if (start_sec >= 0 && end_sec >= 0) {
                        total_duration = end_sec - start_sec
                        if (total_duration < 0) total_duration += 86400
                        # Gaps between consecutive suppressed cycles (3rd onward)
                        for (r = 3; r <= rep_count; r++) {
                            prev_ts  = timestamps[i + plen*(r-2)]
                            curr_ts  = timestamps[i + plen*(r-1)]
                            prev_sec = timestamp_to_seconds(prev_ts)
                            curr_sec = timestamp_to_seconds(curr_ts)
                            if (prev_sec >= 0 && curr_sec >= 0) {
                                gap = curr_sec - prev_sec
                                if (gap < 0) gap += 86400
                                gap_count++; gaps[gap_count] = gap
                            }
                        }
                    }

                    timing_type = classify_timing(gap_count, gaps, total_duration)

                    rate = 0; avg_gap = 0
                    if (gap_count > 0) {
                        sum_gaps = 0
                        for (g = 1; g <= gap_count; g++) sum_gaps += gaps[g]
                        avg_gap = sum_gaps / gap_count
                        if (avg_gap > 0) rate = 1 / avg_gap
                    } else if (total_duration > 0) {
                        rate = suppressed_count / total_duration
                        if (timing_type == "sporadic" && rate > 10)
                            timing_type = "burst"
                    }

                    timing_detail = build_timing_detail(timing_type, rate, avg_gap, total_duration, gap_count)

                    # Build window string
                    if (ts_start_hms == ts_end_hms)
                        window_str = "at " ts_start_hms
                    else
                        window_str = ts_start_hms "-" ts_end_hms

                    # Phase 1 format: L-message pattern
                    behavior_str = timing_type
                    if (timing_detail != "") behavior_str = behavior_str " " timing_detail
                    print "[SUPPRESS] " plen "-message pattern repeated " suppressed_count " times (" behavior_str ", " window_str ")"

                    # Sporadic timestamps with date brackets (Phase 1 format)
                    if (timing_type == "sporadic") {
                        delete supp_ts; supp_count = 0
                        for (r = 3; r <= rep_count; r++) {
                            supp_count++
                            supp_ts[supp_count] = timestamps[i + plen*(r-1)]
                        }
                        if (supp_count > 0) {
                            ts_list = build_sporadic_ts(supp_ts, 1, supp_count)
                            if (ts_list != "") print "  At: " ts_list
                        }
                    }

                    i += plen * rep_count; found = 1
                }
            }
        }

        if (!found) { print lines[i]; i++ }
    }
}
' "$INPUT_FILE" > "$TEMP_FILE"

    # Append or overwrite output file
    if [ -f "$TEMP_FILE" ]; then
        if [ "$APPEND_MODE" -eq 1 ]; then
            cat "$TEMP_FILE" >> "$OUTPUT_FILE"
        else
            mv "$TEMP_FILE" "$OUTPUT_FILE"
            return
        fi
        rm -f "$TEMP_FILE"
    fi
}

# ------------------------------------------------------------
# suppress_log_file_incremental <input_file> <output_file> <offset_file> <in_place>
#
#   Core incremental logic:
#     For SEPARATE OUTPUT mode (in_place=0):
#       1. Read previously saved offset (lines already processed from input).
#       2. Extract only the NEW lines from input (tail from offset+1).
#       3. Suppress and APPEND to output file.
#       4. Update offset to current input line count.
#
#     For IN-PLACE mode (in_place=1):
#       1. First run: Suppress entire file, save OUTPUT line count as offset.
#       2. Subsequent runs:
#          - Offset = lines already suppressed in file
#          - New lines = current total - offset (appended by syslog)
#          - Extract new lines, suppress them, append to file
#          - Update offset = new total line count
# ------------------------------------------------------------
suppress_log_file_incremental() {
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local OFFSET_FILE="$3"
    local IN_PLACE="${4:-0}"

    # Count total lines in the file
    local total_lines
    total_lines=$(wc -l < "$INPUT_FILE" 2>/dev/null | tr -d ' ')
    if [ -z "$total_lines" ] || ! echo "$total_lines" | grep -qE '^[0-9]+$'; then
        total_lines=0
    fi

    # Skip if file is empty
    if [ "$total_lines" -eq 0 ]; then
        TOTAL_SKIPPED_FILES=$((TOTAL_SKIPPED_FILES + 1))
        return 0
    fi

    # Get the previously processed/suppressed line count (0 on first run)
    local prev_offset
    prev_offset=$(get_offset "$OFFSET_FILE")

    # For IN-PLACE mode
    if [ "$IN_PLACE" -eq 1 ]; then
        # First run (no offset exists): suppress entire file
        if [ "$prev_offset" -eq 0 ]; then
            echo_t "  [in-place:first] $(basename "$INPUT_FILE"): suppressing all $total_lines line(s)"
            
            # Track input lines
            echo "$total_lines" >> /tmp/.log_suppress_input_count
            
            # Process entire file, write to temp
            local TEMP_OUT="${OUTPUT_FILE}.suppress.out"
            suppress_log_file "$INPUT_FILE" "$TEMP_OUT" 0 "$MAX_PATTERN_LENGTH"
            
            # Count output lines (suppressed)
            local output_lines=$(wc -l < "$TEMP_OUT" 2>/dev/null | tr -d ' ')
            [ -z "$output_lines" ] && output_lines=0
            echo "$output_lines" >> /tmp/.log_suppress_output_count
            
            # Replace original with suppressed version
            mv "$TEMP_OUT" "$OUTPUT_FILE"
            
            # Log per-file stats
            local saved=$((total_lines - output_lines))
            local pct=0
            [ "$total_lines" -gt 0 ] && pct=$((saved * 100 / total_lines))
            echo "$(basename "$INPUT_FILE")|$total_lines|$output_lines|$saved|$pct" >> /tmp/.log_suppress_per_file

            # Save OUTPUT line count as offset for next run
            set_offset "$OFFSET_FILE" "$output_lines"
            return 0
        fi
        
        # Subsequent runs: check if new lines were appended
        if [ "$total_lines" -le "$prev_offset" ]; then
            # No new lines appended
            TOTAL_SKIPPED_FILES=$((TOTAL_SKIPPED_FILES + 1))
            return 0
        fi
        
        # Calculate new lines (appended after last suppression)
        local new_lines=$((total_lines - prev_offset))
        echo_t "  [in-place:incremental] $(basename "$INPUT_FILE"): $prev_offset suppressed, $new_lines new line(s) to process"
        
        # Track input lines
        echo "$new_lines" >> /tmp/.log_suppress_input_count
        
        # Extract the new lines (everything after prev_offset)
        local SLICE_FILE="${OUTPUT_FILE}.slice.tmp"
        tail -n +"$((prev_offset + 1))" "$INPUT_FILE" > "$SLICE_FILE"
        
        # Suppress the new lines
        local SUPPRESSED_SLICE="${OUTPUT_FILE}.suppressed.tmp"
        suppress_log_file "$SLICE_FILE" "$SUPPRESSED_SLICE" 0 "$MAX_PATTERN_LENGTH"
        
        # Count suppressed output
        local suppressed_new_lines=$(wc -l < "$SUPPRESSED_SLICE" 2>/dev/null | tr -d ' ')
        [ -z "$suppressed_new_lines" ] && suppressed_new_lines=0
        echo "$suppressed_new_lines" >> /tmp/.log_suppress_output_count
        
        # Build new file: [existing suppressed content] + [newly suppressed lines]
        # Keep lines 1 to prev_offset (already suppressed), append new suppressed
        local TEMP_OUT="${OUTPUT_FILE}.final.tmp"
        head -n "$prev_offset" "$INPUT_FILE" > "$TEMP_OUT"
        cat "$SUPPRESSED_SLICE" >> "$TEMP_OUT"
        
        # Replace original
        mv "$TEMP_OUT" "$OUTPUT_FILE"
        
        # Update offset to new total suppressed line count
        local new_offset=$((prev_offset + suppressed_new_lines))
        set_offset "$OFFSET_FILE" "$new_offset"
        
        # Log per-file stats
        local saved=$((new_lines - suppressed_new_lines))
        local pct=0
        [ "$new_lines" -gt 0 ] && pct=$((saved * 100 / new_lines))
        echo "$(basename "$INPUT_FILE")|$new_lines|$suppressed_new_lines|$saved|$pct" >> /tmp/.log_suppress_per_file

        # Cleanup
        rm -f "$SLICE_FILE" "$SUPPRESSED_SLICE"
        return 0
    fi

    # SEPARATE OUTPUT mode: use original incremental logic
    # Nothing new to process
    if [ "$total_lines" -le "$prev_offset" ]; then
        TOTAL_SKIPPED_FILES=$((TOTAL_SKIPPED_FILES + 1))
        return 0
    fi

    local new_lines=$(( total_lines - prev_offset ))
    echo_t "  [incremental] $(basename "$INPUT_FILE"): $prev_offset lines already processed, $new_lines new line(s) to suppress"
    
    # Track input lines for statistics
    echo "$new_lines" >> /tmp/.log_suppress_input_count
    
    # Extract only the new lines into a temporary slice
    local SLICE_FILE="${OUTPUT_FILE}.slice.tmp"
    tail -n +"$(( prev_offset + 1 ))" "$INPUT_FILE" > "$SLICE_FILE"
    
    # Count output lines before suppression
    local output_before=0
    [ -f "$OUTPUT_FILE" ] && output_before=$(wc -l < "$OUTPUT_FILE" 2>/dev/null | tr -d ' ')
    
    # First run: create the output file from scratch (overwrite)
    # Subsequent runs: append suppressed new lines to existing output
    if [ "$prev_offset" -eq 0 ]; then
        suppress_log_file "$SLICE_FILE" "$OUTPUT_FILE" 0 "$MAX_PATTERN_LENGTH"
    else
        suppress_log_file "$SLICE_FILE" "$OUTPUT_FILE" 1 "$MAX_PATTERN_LENGTH"
    fi
    
    # Count output lines after suppression
    local output_after=$(wc -l < "$OUTPUT_FILE" 2>/dev/null | tr -d ' ')
    local lines_written=$((output_after - output_before))
    [ "$lines_written" -lt 0 ] && lines_written=$output_after
    
    # Track output lines
    echo "$lines_written" >> /tmp/.log_suppress_output_count
    
    # Log per-file stats
    local saved=$((new_lines - lines_written))
    local pct=0
    [ "$new_lines" -gt 0 ] && pct=$((saved * 100 / new_lines))
    echo "$(basename "$INPUT_FILE")|$new_lines|$lines_written|$saved|$pct" >> /tmp/.log_suppress_per_file

    rm -f "$SLICE_FILE"
    
    # Persist the new offset
    set_offset "$OFFSET_FILE" "$total_lines"
}

# Main function to suppress logs in all files in a directory
# Only processes NON-RDK logger component files
suppress_logs_in_directory() {
    local dir="$1"
    local outdir="$2"
    
    local processed=0
    local skipped=0
    local skipped_rdk=0
    local total=0
    local size_before=0
    local size_after=0
    
    # Initialize line counters for this run (using temp files for cross-function persistence)
    rm -f /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count /tmp/.log_suppress_per_file
    touch /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count /tmp/.log_suppress_per_file
    TOTAL_SKIPPED_FILES=0
    
    # Log suppression session start
    log_suppress_stats "========================================================"
    log_suppress_stats "LOG SUPPRESSION SESSION STARTED"
    log_suppress_stats "========================================================"
    log_suppress_stats "Input directory: $dir"
    log_suppress_stats "Output directory: $outdir"
    log_suppress_stats "Log Suppression Enabled: $LOG_SUPPRESS_ENABLED"
    log_suppress_stats "Pattern Length: $MAX_PATTERN_LENGTH"
    if [ "$LOG_SUPPRESS_IN_PLACE" -eq 1 ]; then
        log_suppress_stats "Mode: In-place"
    else
        log_suppress_stats "Mode: Separate output"
    fi
    
    # Start CPU monitoring
    init_cpu_monitor
    
    # Calculate total size BEFORE suppression (excluding offsets dir)
    # Measure BEFORE the offset clearing and processing to get pure log size
    offset_size_before=`du -sk "$OFFSET_DIR" 2>/dev/null | awk '{print $1}'`
    [ -z "$offset_size_before" ] && offset_size_before=0
    
    total_dir_before=`du -sk "$dir" 2>/dev/null | awk '{print $1}'`
    [ -z "$total_dir_before" ] && total_dir_before=0
    
    size_before=$((total_dir_before - offset_size_before))
    [ "$size_before" -lt 0 ] 2>/dev/null && size_before=0
    
    # Log size at sync stage
    log_size_tracking "AFTER_SYNC_BEFORE_SUPPRESS" "$dir" "$size_before"
    
    # Count total files
    for file in "$dir"/*; do
        if [ -f "$file" ]; then
            total=$((total + 1))
        fi
    done
    
    echo_t "Starting log suppression: Processing $total file(s) from $dir"
    echo_t "Note: Only non-RDK logger component files will be suppressed"
    echo_t "Size before suppression: ${size_before} KB"
    
    for file in "$dir"/*; do
        # Skip if not a regular file
        if [ ! -f "$file" ]; then
            continue
        fi
        
        # Skip tar files and other binary files
        case "$file" in
            *.tgz|*.tar|*.gz|*.bin|*.core|*.suppress.tmp|*.slice.tmp|*.offset)
                continue
                ;;
        esac
        
        FILENAME=$(basename "$file")
        
        # Skip files that are just offset markers (first line is just a number)
        # BusyBox compatible: use head -1 instead of head -n 1
        first_line=$(head -1 "$file" 2>/dev/null)
        line_count=$(wc -l < "$file" 2>/dev/null)
        if echo "$first_line" | grep -q "^[0-9]*$" && [ "$line_count" -le 2 ]; then
            continue
        fi
        
        # **KEY CHECK**: Skip RDK logger component files
        # These files log through rdk_logger and should NOT be suppressed
        if is_rdk_logger_file "$file"; then
            echo_t "  [SKIP-RDK] $(basename "$file"): RDK logger component file - not suppressing"
            skipped_rdk=$((skipped_rdk + 1))
            continue
        fi
        
        # Determine output path and offset file path
        local OUT_FILE
        local OFFSET_FILE
        
        if [ "$LOG_SUPPRESS_IN_PLACE" -eq 1 ]; then
            OUT_FILE="$file"
        else
            OUT_FILE="$outdir/$FILENAME"
        fi
        OFFSET_FILE="$OFFSET_DIR/${FILENAME}.offset"
        
        # Use incremental suppression:
        #   - For in-place mode: process entire file each time (no incremental)
        #   - For separate output: if offset exists, only process new lines
        suppress_log_file_incremental "$file" "$OUT_FILE" "$OFFSET_FILE" "$LOG_SUPPRESS_IN_PLACE"
        
        processed=$((processed + 1))
        
        # Sample CPU every 3 files
        [ $((processed % 3)) -eq 0 ] && sample_cpu
    done
    
    # Calculate total size after suppression, excluding the offset tracking directory
    # BusyBox du does not support --exclude, so subtract offset dir size manually
    offset_size_after=`du -sk "$OFFSET_DIR" 2>/dev/null | awk '{print $1}'`
    [ -z "$offset_size_after" ] && offset_size_after=0
    
    if [ "$LOG_SUPPRESS_IN_PLACE" -eq 1 ]; then
        total_dir_after=`du -sk "$dir" 2>/dev/null | awk '{print $1}'`
    else
        total_dir_after=`du -sk "$outdir" 2>/dev/null | awk '{print $1}'`
    fi
    [ -z "$total_dir_after" ] && total_dir_after=0
    
    size_after=$((total_dir_after - offset_size_after))
    if [ "$size_after" -lt 0 ] 2>/dev/null; then
        size_after=0
    fi
    
    # Log size AFTER suppression (ready for cloud upload)
    log_size_tracking "AFTER_SUPPRESS_READY_FOR_UPLOAD" "$dir" "$size_after"
    
    # Calculate size reduction
    local size_saved=$((size_before - size_after))
    local size_reduction_pct=0
    if [ "$size_before" -gt 0 ]; then
        size_reduction_pct=$((size_saved * 100 / size_before))
    fi
    
    # Calculate line-based reduction from temp files (sum all values)
    local TOTAL_INPUT_LINES=0
    local TOTAL_OUTPUT_LINES=0
    if [ -f /tmp/.log_suppress_input_count ]; then
        TOTAL_INPUT_LINES=$(awk '{s+=$1} END {print s+0}' /tmp/.log_suppress_input_count 2>/dev/null)
    fi
    if [ -f /tmp/.log_suppress_output_count ]; then
        TOTAL_OUTPUT_LINES=$(awk '{s+=$1} END {print s+0}' /tmp/.log_suppress_output_count 2>/dev/null)
    fi
    
    local lines_saved=$((TOTAL_INPUT_LINES - TOTAL_OUTPUT_LINES))
    local line_reduction_pct=0
    if [ "$TOTAL_INPUT_LINES" -gt 0 ]; then
        line_reduction_pct=$((lines_saved * 100 / TOTAL_INPUT_LINES))
    fi
    
    # Files with new content vs skipped (already up-to-date)
    local files_with_new_content=$((processed - TOTAL_SKIPPED_FILES))
    
    # Log comprehensive statistics to dedicated file
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "PER-FILE SUPPRESSION:"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "  File                          | Lines In | Lines Out | Saved | %"
    log_suppress_stats "  ------------------------------|----------|-----------|-------|---"
    if [ -s /tmp/.log_suppress_per_file ]; then
        while IFS='|' read -r fname fin fout fsaved fpct; do
            log_suppress_stats "  $(printf '%-30s' "$fname")| $(printf '%8s' "$fin") | $(printf '%9s' "$fout") | $(printf '%5s' "$fsaved") | ${fpct}%"
        done < /tmp/.log_suppress_per_file
    fi
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "SUPPRESSION RESULTS:"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "  Total files in directory: $total"
    log_suppress_stats "  Non-RDK files processed: $processed"
    log_suppress_stats "  RDK logger files skipped: $skipped_rdk"
    log_suppress_stats "  Files with new content: $files_with_new_content"
    log_suppress_stats "  Files already up-to-date: $TOTAL_SKIPPED_FILES"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "SIZE TRACKING:"
    log_suppress_stats "  Size after sync (before suppression): ${size_before} KB"
    log_suppress_stats "  Size after suppression (for upload):  ${size_after} KB"
    log_suppress_stats "  Size saved: ${size_saved} KB (${size_reduction_pct}% reduction)"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "LINE TRACKING:"
    log_suppress_stats "  Lines input:  $TOTAL_INPUT_LINES"
    log_suppress_stats "  Lines output: $TOTAL_OUTPUT_LINES"
    log_suppress_stats "  Lines saved:  $lines_saved (${line_reduction_pct}% reduction)"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "CONFIGURATION:"
    log_suppress_stats "  Log Suppression Enabled: $LOG_SUPPRESS_ENABLED"
    log_suppress_stats "  Pattern Length: $MAX_PATTERN_LENGTH"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "LOG SUPPRESSION SESSION ENDED"
    log_suppress_stats "========================================================"
    log_suppress_stats ""
    
    # Also print summary to console
    echo_t "Log suppression completed: Processed $processed non-RDK files, skipped $skipped_rdk RDK logger files"
    echo_t "  Files with new content: $files_with_new_content, Already up-to-date: $TOTAL_SKIPPED_FILES"
    echo_t "SIZE: Before=${size_before}KB -> After=${size_after}KB (saved ${size_saved}KB, ${size_reduction_pct}%)"
    echo_t "LINES: ${TOTAL_INPUT_LINES} input -> ${TOTAL_OUTPUT_LINES} output (saved ${lines_saved}, ${line_reduction_pct}%)"
    echo_t "Stats logged to: $LOG_SUPPRESS_STATS_LOG"
    
    # Cleanup temp files
    rm -f /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count /tmp/.log_suppress_per_file
    
    # Report CPU overhead
    report_cpu_overhead
}

# Execute suppression
suppress_logs_in_directory "$LOG_SUPPRESS_INPUT_DIR" "$LOG_SUPPRESS_OUTPUT_DIR"
