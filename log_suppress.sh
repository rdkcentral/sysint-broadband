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
# Log Suppression Script
# This script analyzes log files and suppresses repeated log patterns
# to reduce log size before upload
#
# Usage: log_suppress.sh <input_directory> [output_directory]
# If output_directory is not provided, files are suppressed in-place
#
# Incremental suppression:
#   Offset files are stored alongside output as <filename>.offset
#   Each offset file contains the number of lines already processed.
#   On subsequent runs, only new lines (beyond the offset) are suppressed
#   and appended to the existing output file.
##########################################################################

# Source echo_t function if available
if [ -f /lib/rdk/utils.sh ]; then
    . /lib/rdk/utils.sh
else
    # Fallback echo_t function
    echo_t() {
        echo "`date +"%y%m%d-%T.%6N"` $1"
    }
fi

LOG_SUPPRESS_INPUT_DIR="$1"
LOG_SUPPRESS_OUTPUT_DIR="$2"
LOG_SUPPRESS_FRESH="$3"

# If output directory not provided, use input directory (in-place)
if [ -z "$LOG_SUPPRESS_OUTPUT_DIR" ] || [ "$LOG_SUPPRESS_OUTPUT_DIR" = "--fresh" ]; then
    if [ "$LOG_SUPPRESS_OUTPUT_DIR" = "--fresh" ]; then
        LOG_SUPPRESS_FRESH="--fresh"
    fi
    LOG_SUPPRESS_OUTPUT_DIR="$LOG_SUPPRESS_INPUT_DIR"
    LOG_SUPPRESS_IN_PLACE=1
else
    LOG_SUPPRESS_IN_PLACE=0
fi

# Check if input directory is provided
if [ -z "$LOG_SUPPRESS_INPUT_DIR" ]; then
    echo_t "Usage: $0 <input_directory> [output_directory] [--fresh]"
    echo_t "  --fresh : Clear all offset files and reprocess all logs from scratch"
    exit 1
fi

if [ ! -d "$LOG_SUPPRESS_INPUT_DIR" ]; then
    echo_t "Error: Input directory '$LOG_SUPPRESS_INPUT_DIR' not found"
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$LOG_SUPPRESS_OUTPUT_DIR"

# Directory to store offset files (tracks how many lines were already processed per file)
OFFSET_DIR="$LOG_SUPPRESS_OUTPUT_DIR/.log_suppress_offsets"
mkdir -p "$OFFSET_DIR"

# Clear offsets if --fresh flag is provided
if [ "$LOG_SUPPRESS_FRESH" = "--fresh" ]; then
    echo_t "Fresh mode: Clearing all offset files to reprocess logs from scratch"
    rm -f "$OFFSET_DIR"/*.offset 2>/dev/null
fi

# ------------------------------------------------------------
# get_offset <offset_file>
#   Reads the stored line offset for a given file.
#   Returns 0 if no offset exists yet (first run).
# ------------------------------------------------------------
get_offset()
{
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
set_offset()
{
    local offset_file="$1"
    local value="$2"
    echo "$value" > "$offset_file"
}

# ------------------------------------------------------------
# CPU Overhead Monitoring Functions (using top command)
# ------------------------------------------------------------

# Log file for CPU overhead reports
CPU_OVERHEAD_LOG="/rdklogs/logs/log_suppress_cpu_overhead.txt"

# Dedicated log file for suppression statistics
LOG_SUPPRESS_STATS_LOG="/rdklogs/logs/log_suppress_stats.txt"

# Log function that writes to both stdout and dedicated log file
log_cpu_overhead()
{
    local msg="$1"
    echo_t "$msg"
    echo "`date +"%y%m%d-%T.%6N"` $msg" >> "$CPU_OVERHEAD_LOG" 2>/dev/null
}

# Log function for suppression statistics - writes to dedicated stats file
log_suppress_stats()
{
    local msg="$1"
    echo_t "$msg"
    echo "`date +"%y%m%d-%T.%6N"` $msg" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
}

# Log size tracking entry
log_size_tracking()
{
    local stage="$1"
    local dir="$2"
    local size_kb="$3"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Log to stats file in CSV-like format for easy parsing
    echo "${timestamp},${stage},${dir},${size_kb}KB" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
    echo_t "SIZE_TRACK [${stage}]: ${dir} = ${size_kb} KB"
}

# Capture CPU snapshot using top command
capture_top_snapshot()
{
    local label="$1"
    local output_file="/tmp/log_suppress_top_${label}.txt"
    
    # Run top in batch mode with 2 iterations to get actual CPU usage (first iteration is cumulative)
    # BusyBox compatible: use head -5 not head -n 5
    top -b -n 2 -d 1 2>/dev/null | tail -10 | head -5 > "$output_file" 2>/dev/null
    
    # Parse CPU line: "CPU:   3% usr   6% sys   0% nic  89% idle..."
    # Or: "%Cpu(s):  3.0 us,  6.0 sy,  0.0 ni, 89.0 id..."
    local cpu_line=$(grep -E "^(%Cpu|CPU:)" "$output_file" 2>/dev/null)
    
    local usr_cpu=0
    local sys_cpu=0
    local idle_cpu=0
    
    if echo "$cpu_line" | grep -q "CPU:"; then
        # Busybox format: "CPU:   3% usr   6% sys   0% nic  89% idle..."
        usr_cpu=$(echo "$cpu_line" | sed 's/.*[[:space:]]\([0-9]*\)% usr.*/\1/' 2>/dev/null)
        sys_cpu=$(echo "$cpu_line" | sed 's/.*[[:space:]]\([0-9]*\)% sys.*/\1/' 2>/dev/null)
        idle_cpu=$(echo "$cpu_line" | sed 's/.*[[:space:]]\([0-9]*\)% idle.*/\1/' 2>/dev/null)
    else
        # Standard top format: "%Cpu(s):  3.0 us,  6.0 sy,  0.0 ni, 89.0 id..."
        # BusyBox compatible: avoid grep -oE, use awk instead
        usr_cpu=$(echo "$cpu_line" | awk -F',' '{print $1}' | awk '{gsub(/[^0-9]/,"",$NF); print $NF}' 2>/dev/null)
        sys_cpu=$(echo "$cpu_line" | awk -F',' '{print $2}' | awk '{gsub(/[^0-9]/,"",$NF); print $NF}' 2>/dev/null)
        idle_cpu=$(echo "$cpu_line" | awk -F',' '{print $4}' | awk '{gsub(/[^0-9]/,"",$NF); print $NF}' 2>/dev/null)
    fi
    
    # Handle empty values (ensure numeric)
    usr_cpu=$(echo "$usr_cpu" | grep -E '^[0-9]+$' || echo 0)
    sys_cpu=$(echo "$sys_cpu" | grep -E '^[0-9]+$' || echo 0)
    idle_cpu=$(echo "$idle_cpu" | grep -E '^[0-9]+$' || echo 0)
    [ -z "$usr_cpu" ] && usr_cpu=0
    [ -z "$sys_cpu" ] && sys_cpu=0
    [ -z "$idle_cpu" ] && idle_cpu=0
    
    local total_cpu=$((usr_cpu + sys_cpu))
    
    # Parse load average from /proc/loadavg (more reliable than parsing top output)
    local load_avg="N/A"
    if [ -r /proc/loadavg ]; then
        load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    else
        # Fallback: try to parse from top output
        local load_line=$(grep -i "load average" "$output_file" 2>/dev/null)
        load_avg=$(echo "$load_line" | sed 's/.*load average:[[:space:]]*//' | awk '{print $1, $2, $3}' | tr -d ',' 2>/dev/null)
    fi
    [ -z "$load_avg" ] && load_avg="N/A"
    
    # Get memory info - try /proc/meminfo with permission check
    local mem_used=0
    local mem_total=0
    local mem_pct=0
    if [ -r /proc/meminfo ]; then
        mem_total=$(cat /proc/meminfo 2>/dev/null | grep MemTotal | awk '{print $2}')
        local mem_free=$(cat /proc/meminfo 2>/dev/null | grep MemFree | awk '{print $2}')
        local mem_buffers=$(cat /proc/meminfo 2>/dev/null | grep Buffers | awk '{print $2}')
        local mem_cached=$(cat /proc/meminfo 2>/dev/null | grep "^Cached:" | awk '{print $2}')
        # Ensure numeric values
        mem_total=${mem_total:-0}
        mem_free=${mem_free:-0}
        mem_buffers=${mem_buffers:-0}
        mem_cached=${mem_cached:-0}
        if [ "$mem_total" -gt 0 ] 2>/dev/null; then
            mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
            mem_pct=$((mem_used * 100 / mem_total))
        fi
    else
        # Fallback: try free command
        local free_output=$(free 2>/dev/null | grep -i mem)
        if [ -n "$free_output" ]; then
            mem_total=$(echo "$free_output" | awk '{print $2}')
            mem_used=$(echo "$free_output" | awk '{print $3}')
            [ "$mem_total" -gt 0 ] 2>/dev/null && mem_pct=$((mem_used * 100 / mem_total))
        fi
    fi
    
    log_cpu_overhead "[$label] CPU: ${total_cpu}% (usr:${usr_cpu}% sys:${sys_cpu}%) | Idle: ${idle_cpu}% | Load: $load_avg | Mem: ${mem_pct}%"
    
    # Store values for comparison
    eval "STATE_${label}_USR=$usr_cpu"
    eval "STATE_${label}_SYS=$sys_cpu"
    eval "STATE_${label}_IDLE=$idle_cpu"
    eval "STATE_${label}_TOTAL=$total_cpu"
    eval "STATE_${label}_LOAD=\"$load_avg\""
    eval "STATE_${label}_MEM=$mem_pct"
    
    # Also save the raw top output
    cat "$output_file" 2>/dev/null
}

# Get process CPU time from /proc/self/stat (utime + stime in jiffies)
get_proc_cpu_time()
{
    if [ -f /proc/self/stat ]; then
        awk '{print $14+$15}' /proc/self/stat 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# Initialize CPU monitoring
init_cpu_monitor()
{
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║  CAPTURING SYSTEM STATE BEFORE LOG SUPPRESSION             ║"
    log_cpu_overhead "╚════════════════════════════════════════════════════════════╝"
    capture_top_snapshot "BEFORE"
    
    CPU_MON_START_SEC=$(date +%s)
    CPU_MON_START_PROC=$(get_proc_cpu_time)
    CPU_MON_PEAK_TOTAL=0
    CPU_MON_SAMPLES=0
    CPU_MON_SUM=0
}

# Sample CPU using top during execution
sample_cpu()
{
    # Quick CPU check using /proc/stat (faster than top)
    if [ -r /proc/stat ]; then
        # BusyBox compatible: use head -1 instead of head -n 1
        local cpu_line=$(head -1 /proc/stat 2>/dev/null)
        local user=$(echo "$cpu_line" | awk '{print $2}')
        local nice=$(echo "$cpu_line" | awk '{print $3}')
        local system=$(echo "$cpu_line" | awk '{print $4}')
        local idle=$(echo "$cpu_line" | awk '{print $5}')
        local total=$((user + nice + system + idle))
        local active=$((user + nice + system))
        
        if [ "$total" -gt 0 ]; then
            local cpu_pct=$((active * 100 / total))
            # This is cumulative, so we track the instantaneous reading differently
            CPU_MON_SUM=$((CPU_MON_SUM + cpu_pct))
            CPU_MON_SAMPLES=$((CPU_MON_SAMPLES + 1))
            [ "$cpu_pct" -gt "$CPU_MON_PEAK_TOTAL" ] && CPU_MON_PEAK_TOTAL=$cpu_pct
        fi
    fi
}

# Report CPU overhead statistics
report_cpu_overhead()
{
    local end_sec=$(date +%s)
    local end_proc=$(get_proc_cpu_time)
    
    # Elapsed time
    local elapsed=$((end_sec - CPU_MON_START_SEC))
    
    # Process-specific CPU time (jiffies to ms, assuming 100Hz)
    local proc_jiffies=$((end_proc - CPU_MON_START_PROC))
    local proc_ms=$((proc_jiffies * 10))
    
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║  CAPTURING SYSTEM STATE AFTER LOG SUPPRESSION              ║"
    log_cpu_overhead "╚════════════════════════════════════════════════════════════╝"
    capture_top_snapshot "AFTER"
    
    # Calculate CPU spike
    local cpu_spike=$((STATE_AFTER_TOTAL - STATE_BEFORE_TOTAL))
    [ "$cpu_spike" -lt 0 ] && cpu_spike=0
    
    local idle_drop=$((STATE_BEFORE_IDLE - STATE_AFTER_IDLE))
    [ "$idle_drop" -lt 0 ] && idle_drop=0
    
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║           LOG SUPPRESSION CPU OVERHEAD REPORT (via top)            ║"
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  Duration: ${elapsed} seconds                                             "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  CPU USAGE COMPARISON:                                             "
    log_cpu_overhead "║  ┌─────────────┬──────────┬──────────┬──────────┬─────────┐        "
    log_cpu_overhead "║  │   State     │  User %  │  Sys %   │  Total % │  Idle % │        "
    log_cpu_overhead "║  ├─────────────┼──────────┼──────────┼──────────┼─────────┤        "
    log_cpu_overhead "║  │  BEFORE     │    ${STATE_BEFORE_USR}%    │    ${STATE_BEFORE_SYS}%    │    ${STATE_BEFORE_TOTAL}%    │   ${STATE_BEFORE_IDLE}%   │        "
    log_cpu_overhead "║  │  AFTER      │    ${STATE_AFTER_USR}%    │    ${STATE_AFTER_SYS}%    │    ${STATE_AFTER_TOTAL}%    │   ${STATE_AFTER_IDLE}%   │        "
    log_cpu_overhead "║  └─────────────┴──────────┴──────────┴──────────┴─────────┘        "
    log_cpu_overhead "║                                                                    "
    log_cpu_overhead "║  CPU SPIKE: +${cpu_spike}%  |  IDLE DROP: -${idle_drop}%                       "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  LOAD AVERAGE:                                                     "
    log_cpu_overhead "║    BEFORE: ${STATE_BEFORE_LOAD}                                    "
    log_cpu_overhead "║    AFTER:  ${STATE_AFTER_LOAD}                                     "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  MEMORY USAGE:                                                     "
    log_cpu_overhead "║    BEFORE: ${STATE_BEFORE_MEM}%  |  AFTER: ${STATE_AFTER_MEM}%                 "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PROCESS STATS:                                                    "
    log_cpu_overhead "║    Script CPU time: ${proc_ms} ms                                  "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    
    # Spike assessment based on top readings
    if [ "$cpu_spike" -gt 30 ] || [ "$idle_drop" -gt 30 ]; then
        log_cpu_overhead "║  ⚠ WARNING: Significant CPU spike detected!                       "
        log_cpu_overhead "║    Recommendation: Consider running with 'nice -n 19'             "
    elif [ "$cpu_spike" -gt 15 ] || [ "$idle_drop" -gt 15 ]; then
        log_cpu_overhead "║  ⚡ MODERATE: Some CPU overhead observed                           "
    else
        log_cpu_overhead "║  ✓ LOW: Minimal CPU impact, no significant spike                   "
    fi
    log_cpu_overhead "╚════════════════════════════════════════════════════════════════════╝"
    log_cpu_overhead "Logs saved to: $CPU_OVERHEAD_LOG"
    
    # Cleanup temp files
    rm -f /tmp/log_suppress_top_BEFORE.txt /tmp/log_suppress_top_AFTER.txt
}

# Function to suppress logs in a single file (or a stream of new lines)
# Arguments:
#   INPUT_FILE  - path to read new lines from (may be a temp slice file)
#   OUTPUT_FILE - path to write suppressed output (append mode when incremental)
#   APPEND_MODE - 1 = append to OUTPUT_FILE, 0 = overwrite
suppress_log_file()
{
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local APPEND_MODE="${3:-0}"
    local TEMP_FILE="${OUTPUT_FILE}.suppress.tmp"

    awk '
BEGIN {
    idx = 0
}

{
    # Skip empty lines
    if (length($0) == 0 || $0 ~ /^[[:space:]]*$/) {
        next
    }

    idx++
    lines[idx] = $0
    has_timestamp = 0
    timestamp = ""
    message = ""

    # Try to extract timestamp - supports multiple formats
    # Format: YYMMDD-HH:MM:SS.microseconds (6 digits for date)
    if (match($0, /^[0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DD-HH:MM:SS.microseconds or similar dash-separated
    else if (match($0, /^[0-9-]+-[0-9:.]+ /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY MMM DD HH:MM:SS (e.g., 2024 Jan 15 10:30:45)
    else if (match($0, /^[0-9]{4} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: [Day Mon DD HH:MM:SS YYYY] (e.g., [Mon Jan 15 10:30:45 2024])
    else if (match($0, /^\[[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\] /)) {
        timestamp = substr($0, 2, RLENGTH - 2)
        message = substr($0, RLENGTH + 2)
        has_timestamp = 1
    }
    # Format: Day, Mon DD HH:MM:SS YYYY: (e.g., Monday, Jan 15 10:30:45 2024:)
    else if (match($0, /^[A-Za-z]+, [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}:/)) {
        timestamp = substr($0, 1, RLENGTH - 1)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYYMMDD HHMMSS.microseconds (e.g., 20240115 103045.123456)
    else if (match($0, /^[0-9]{8} [0-9]{6}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: Day Mon DD HH:MM:SS TZ YYYY or Day Mon DD HH:MM:SS YYYY
    else if (match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z]{3} [0-9]{4} /) || match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: [OneWifi] YYMMDD-HH:MM:SS.microseconds<I/E>
    else if (match($0, /^\[OneWifi\] [0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}<[IE]> /)) {
        timestamp = substr($0, 11, 17)
        message = substr($0, 30)
        has_timestamp = 1
    }
    # Format: YYYY.MM.DD HH:MM:SS (e.g., 2024.01.15 10:30:45)
    else if (match($0, /^[0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
        timestamp = substr($0, 1, 19)
        message = substr($0, 21)
        has_timestamp = 1
    }
    # Format: [HH:MM:SS DD/MM/YYYY] (time and date in brackets)
    else if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{2}\/[0-9]{2}\/[0-9]{4})\] /)) {
        timestamp = substr($0, 2, RLENGTH - 3)
        message = substr($0, RLENGTH + 2)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DD HH:MM:SS.microseconds (standard datetime)
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DDTHH:MM:SS.microsecondsZ: (ISO format)
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*:/)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # No timestamp found - treat entire line as message
    else {
        has_timestamp = 0
        timestamp = ""
        message = $0
    }

    timestamps[idx] = timestamp
    content[idx] = message
    gsub(/^[ \t]+/, "", content[idx])
}

END {
    i = 1
    while (i <= idx) {
        found = 0

        # If line has no timestamp, print as-is and skip pattern detection
        if (timestamps[i] == "") {
            print lines[i]
            i++
            continue
        }

        # First check for single line repetition
        if (i < idx && content[i] == content[i+1]) {
            rep_count = 1
            j = i + 1
            while (j <= idx && content[i] == content[j] && timestamps[j] != "") {
                rep_count++
                j++
            }

            if (rep_count > 1) {
                # Single line repetition - show inline suppression
                ts_list = ""
                for (r = 1; r < rep_count; r++) {
                    if (ts_list != "") ts_list = ts_list ","
                    ts_list = ts_list "<" timestamps[i + r] ">"
                }
                print lines[i] " [suppressed count: " (rep_count - 1) ", timestamps: " ts_list "]"
                i += rep_count
                found = 1
            }
        }

        # If not single line repetition, try multi-line patterns (2 lines up to N lines)
        if (!found) {
            max_pattern_len = 10
            if (idx - i < max_pattern_len) max_pattern_len = idx - i

            for (plen = 2; plen <= max_pattern_len && !found; plen++) {
                if (i + plen > idx) continue

                rep_count = 1
                can_continue = 1

                while (can_continue && i + plen * (rep_count + 1) <= idx) {
                    matches = 1
                    for (k = 0; k < plen; k++) {
                        if (content[i + k] != content[i + plen * rep_count + k] || timestamps[i + plen * rep_count + k] == "") {
                            matches = 0
                            break
                        }
                    }

                    if (matches) {
                        rep_count++
                    } else {
                        can_continue = 0
                    }
                }

                if (rep_count > 1) {
                    for (k = 0; k < plen; k++) {
                        print lines[i + k]
                    }

                    ts_start = timestamps[i + plen]
                    ts_end = timestamps[i + plen * (rep_count - 1) + plen - 1]

                    if (rep_count == 2) {
                        print "[Above " plen " lines occurred immediately, pattern suppressed, count:" (rep_count - 1) ",timestamps: [" ts_start "] to[" ts_end "]]"
                    } else {
                        print "[Above " plen " lines occurred, pattern suppressed, count:" (rep_count - 1) ",timestamps: [" ts_start "] to[" ts_end "]]"
                    }

                    i += plen * rep_count
                    found = 1
                }
            }
        }

        # No pattern found, print line as-is
        if (!found) {
            print lines[i]
            i++
        }
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
# suppress_log_file_incremental <input_file> <output_file> <offset_file>
#
#   Core incremental logic:
#     1. Read previously saved offset (lines already processed).
#     2. Count current total lines in input file.
#     3. If no new lines, skip the file entirely.
#     4. Extract only the NEW lines (tail from offset+1 onward) into a
#        temporary slice file.
#     5. Run suppression on that slice and APPEND the result to output.
#     6. Update the offset to the new total line count.
# ------------------------------------------------------------
suppress_log_file_incremental()
{
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local OFFSET_FILE="$3"

    # Get the previously processed line count (0 on first run)
    local prev_offset
    prev_offset=$(get_offset "$OFFSET_FILE")

    # Count total lines in the source file
    local total_lines
    total_lines=$(wc -l < "$INPUT_FILE" 2>/dev/null | tr -d ' ')
    if [ -z "$total_lines" ] || ! echo "$total_lines" | grep -qE '^[0-9]+$'; then
        total_lines=0
    fi

    # Nothing new to process
    if [ "$total_lines" -le "$prev_offset" ]; then
        # Track skipped files
        TOTAL_SKIPPED_FILES=$((TOTAL_SKIPPED_FILES + 1))
        return 0
    fi

    local new_lines=$(( total_lines - prev_offset ))
    echo_t "  [incremental] $(basename "$INPUT_FILE"): $prev_offset lines already processed, $new_lines new line(s) to suppress"

    # Track input lines for statistics (use file for cross-function persistence)
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
        suppress_log_file "$SLICE_FILE" "$OUTPUT_FILE" 0
    else
        suppress_log_file "$SLICE_FILE" "$OUTPUT_FILE" 1
    fi

    # Count output lines after suppression
    local output_after=$(wc -l < "$OUTPUT_FILE" 2>/dev/null | tr -d ' ')
    local lines_written=$((output_after - output_before))
    [ "$lines_written" -lt 0 ] && lines_written=$output_after
    
    # Track output lines (use file for cross-function persistence)
    echo "$lines_written" >> /tmp/.log_suppress_output_count

    rm -f "$SLICE_FILE"

    # Persist the new offset so next run knows where to continue from
    set_offset "$OFFSET_FILE" "$total_lines"
}

# Main function to suppress logs in all files in a directory
suppress_logs_in_directory()
{
    local dir="$1"
    local outdir="$2"
    local processed=0
    local skipped=0
    local total=0
    local size_before=0
    local size_after=0

    # Initialize line counters for this run (using temp files for cross-function persistence)
    rm -f /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count
    touch /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count
    TOTAL_SKIPPED_FILES=0

    # Log suppression session start
    log_suppress_stats "========================================================"
    log_suppress_stats "LOG SUPPRESSION SESSION STARTED"
    log_suppress_stats "========================================================"
    log_suppress_stats "Input directory: $dir"
    log_suppress_stats "Output directory: $outdir"
    log_suppress_stats "Mode: $([ \"$LOG_SUPPRESS_IN_PLACE\" -eq 1 ] && echo 'In-place' || echo 'Separate output')"

    # Start CPU monitoring
    init_cpu_monitor

    # Calculate total size BEFORE suppression (this is after nvram2 sync)
    size_before=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    [ -z "$size_before" ] && size_before=0
    
    # Log size at sync stage
    log_size_tracking "AFTER_SYNC_BEFORE_SUPPRESS" "$dir" "$size_before"
    if [ -z "$size_before" ]; then
        size_before=0
    fi

    # Count total files
    for file in "$dir"/*; do
        if [ -f "$file" ]; then
            total=$((total + 1))
        fi
    done

    echo_t "Starting log suppression: Processing $total file(s) from $dir"
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
        #   - If an offset exists for this file, only process new lines.
        #   - If no offset exists, full suppression (first time).
        suppress_log_file_incremental "$file" "$OUT_FILE" "$OFFSET_FILE"

        processed=$((processed + 1))

        # Sample CPU every 3 files
        [ $((processed % 3)) -eq 0 ] && sample_cpu
    done

    # Calculate total size after suppression, excluding the offset tracking directory
    if [ "$LOG_SUPPRESS_IN_PLACE" -eq 1 ]; then
        size_after=$(du -sk --exclude=".log_suppress_offsets" "$dir" 2>/dev/null | awk '{print $1}')
        # Fallback for systems where --exclude is unsupported (e.g. busybox du)
        if [ -z "$size_after" ]; then
            offset_size=$(du -sk "$OFFSET_DIR" 2>/dev/null | awk '{print $1}')
            size_after=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
            size_after=$(( ${size_after:-0} - ${offset_size:-0} ))
        fi
    else
        size_after=$(du -sk --exclude=".log_suppress_offsets" "$outdir" 2>/dev/null | awk '{print $1}')
        # Fallback for systems where --exclude is unsupported (e.g. busybox du)
        if [ -z "$size_after" ]; then
            offset_size=$(du -sk "$OFFSET_DIR" 2>/dev/null | awk '{print $1}')
            size_after=$(du -sk "$outdir" 2>/dev/null | awk '{print $1}')
            size_after=$(( ${size_after:-0} - ${offset_size:-0} ))
        fi
    fi
    if [ -z "$size_after" ] || [ "$size_after" -lt 0 ]; then
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
    log_suppress_stats "SUPPRESSION RESULTS:"
    log_suppress_stats "--------------------------------------------------------"
    log_suppress_stats "  Files processed: $processed/$total"
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
    log_suppress_stats "LOG SUPPRESSION SESSION ENDED"
    log_suppress_stats "========================================================"
    log_suppress_stats ""

    # Also print summary to console
    echo_t "Log suppression completed: Processed $processed/$total files"
    echo_t "  Files with new content: $files_with_new_content, Already up-to-date: $TOTAL_SKIPPED_FILES"
    echo_t "SIZE: Before=${size_before}KB -> After=${size_after}KB (saved ${size_saved}KB, ${size_reduction_pct}%)"
    echo_t "LINES: ${TOTAL_INPUT_LINES} input -> ${TOTAL_OUTPUT_LINES} output (saved ${lines_saved}, ${line_reduction_pct}%)"
    echo_t "Stats logged to: $LOG_SUPPRESS_STATS_LOG"

    # Cleanup temp files
    rm -f /tmp/.log_suppress_input_count /tmp/.log_suppress_output_count

    # Report CPU overhead
    report_cpu_overhead
}

# Execute suppression
suppress_logs_in_directory "$LOG_SUPPRESS_INPUT_DIR" "$LOG_SUPPRESS_OUTPUT_DIR"
