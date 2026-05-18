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

# Enable/disable toggle: suppression is ON by default, skip only if disable file exists
LOG_SUPPRESS_DISABLE="/nvram2/.log_suppression_disabled"
if [ -f "$LOG_SUPPRESS_DISABLE" ]; then
    echo_t "Log suppression disabled ($LOG_SUPPRESS_DISABLE found). Skipping."
    exit 0
fi

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
# Per-Process CPU Overhead Monitoring Functions
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
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $msg" >> "$CPU_OVERHEAD_LOG" 2>/dev/null
}

# Log function for suppression statistics - writes to dedicated stats file
log_suppress_stats()
{
    local msg="$1"
    echo_t "$msg"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $msg" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
}

# Log size tracking entry
log_size_tracking()
{
    local stage="$1"
    local dir="$2"
    local size_kb="$3"
    local timestamp=`date '+%Y-%m-%d %H:%M:%S'`
    
    # Log to stats file
    echo "[$timestamp] SIZE_TRACK [$stage] $dir Size=${size_kb}KB" >> "$LOG_SUPPRESS_STATS_LOG" 2>/dev/null
    echo_t "SIZE_TRACK [${stage}]: ${dir} = ${size_kb} KB"
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

# Get CPU usage for a specific process by PID using ps
# Returns: cpu_percent
get_process_cpu_usage()
{
    local pid="$1"
    local cpu_pct=0
    
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        # Use ps to get CPU percentage for the specific process
        cpu_pct=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' | cut -d'.' -f1)
        [ -z "$cpu_pct" ] && cpu_pct=0
        echo "$cpu_pct" | grep -qE '^[0-9]+$' || cpu_pct=0
    fi
    
    echo "$cpu_pct"
}

# Get memory usage for a specific process by PID using ps
# Returns: mem_percent
get_process_mem_usage()
{
    local pid="$1"
    local mem_pct=0
    
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        # Use ps to get memory percentage for the specific process
        mem_pct=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ' | cut -d'.' -f1)
        [ -z "$mem_pct" ] && mem_pct=0
        echo "$mem_pct" | grep -qE '^[0-9]+$' || mem_pct=0
    fi
    
    echo "$mem_pct"
}

# Get process command name by PID
get_process_cmd()
{
    local pid="$1"
    local cmd=""
    
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
        cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
        [ -z "$cmd" ] && cmd="unknown"
    fi
    
    echo "$cmd"
}

# Initialize per-process CPU monitoring
init_cpu_monitor()
{
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║  PER-PROCESS CPU MONITORING STARTED                        ║"
    log_cpu_overhead "╚════════════════════════════════════════════════════════════╝"
    
    CPU_MON_START_SEC=$(date +%s)
    CPU_MON_START_PROC=$(get_proc_cpu_time)
    CPU_MON_PID=$$
    CPU_MON_SAMPLES=0
    CPU_MON_SUM=0
    CPU_MON_PEAK=0
    CPU_MON_MEM_PEAK=0
    
    # Initial snapshot
    local init_cpu=$(get_process_cpu_usage $CPU_MON_PID)
    local init_mem=$(get_process_mem_usage $CPU_MON_PID)
    log_cpu_overhead "[INIT] PID: $CPU_MON_PID | Initial CPU: ${init_cpu}% | Initial Mem: ${init_mem}%"
}

# Sample per-process CPU during execution
sample_cpu()
{
    local cpu_pct=$(get_process_cpu_usage $CPU_MON_PID)
    local mem_pct=$(get_process_mem_usage $CPU_MON_PID)
    
    CPU_MON_SUM=$((CPU_MON_SUM + cpu_pct))
    CPU_MON_SAMPLES=$((CPU_MON_SAMPLES + 1))
    [ "$cpu_pct" -gt "$CPU_MON_PEAK" ] && CPU_MON_PEAK=$cpu_pct
    [ "$mem_pct" -gt "$CPU_MON_MEM_PEAK" ] && CPU_MON_MEM_PEAK=$mem_pct
}

# Report per-process CPU overhead statistics
report_cpu_overhead()
{
    local end_sec=$(date +%s)
    local end_proc=$(get_proc_cpu_time)
    
    # Elapsed wall-clock time
    local elapsed=$((end_sec - CPU_MON_START_SEC))
    [ "$elapsed" -eq 0 ] && elapsed=1
    
    # Process-specific CPU time (jiffies to ms, assuming 100Hz)
    local proc_jiffies=$((end_proc - CPU_MON_START_PROC))
    local proc_ms=$((proc_jiffies * 10))
    
    # Calculate CPU overhead percentage (process CPU time / wall clock time)
    local cpu_overhead_pct=0
    if [ "$elapsed" -gt 0 ]; then
        # proc_ms is in milliseconds, elapsed is in seconds
        cpu_overhead_pct=$((proc_ms / (elapsed * 10)))
    fi
    
    # Average CPU from samples
    local avg_cpu=0
    if [ "$CPU_MON_SAMPLES" -gt 0 ]; then
        avg_cpu=$((CPU_MON_SUM / CPU_MON_SAMPLES))
    fi
    
    # Final snapshot
    local final_cpu=$(get_process_cpu_usage $CPU_MON_PID)
    local final_mem=$(get_process_mem_usage $CPU_MON_PID)
    
    log_cpu_overhead ""
    log_cpu_overhead "╔════════════════════════════════════════════════════════════════════╗"
    log_cpu_overhead "║       LOG SUPPRESSION PER-PROCESS CPU OVERHEAD REPORT              ║"
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PROCESS IDENTIFICATION:                                           "
    log_cpu_overhead "║    PID: $CPU_MON_PID                                               "
    log_cpu_overhead "║    Command: $(get_process_cmd $CPU_MON_PID)                        "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  TIMING:                                                           "
    log_cpu_overhead "║    Duration: ${elapsed} seconds                                    "
    log_cpu_overhead "║    Process CPU time: ${proc_ms} ms                                 "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PER-PROCESS CPU USAGE:                                            "
    log_cpu_overhead "║    CPU Overhead: ${cpu_overhead_pct}%                              "
    log_cpu_overhead "║    Peak CPU: ${CPU_MON_PEAK}%                                      "
    log_cpu_overhead "║    Average CPU (sampled): ${avg_cpu}%                              "
    log_cpu_overhead "║    Final CPU: ${final_cpu}%                                        "
    log_cpu_overhead "║    Samples collected: ${CPU_MON_SAMPLES}                           "
    log_cpu_overhead "╠════════════════════════════════════════════════════════════════════╣"
    log_cpu_overhead "║  PER-PROCESS MEMORY USAGE:                                         "
    log_cpu_overhead "║    Peak Memory: ${CPU_MON_MEM_PEAK}%                               "
    log_cpu_overhead "║    Final Memory: ${final_mem}%                                     "
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
suppress_log_file()
{
    local INPUT_FILE="$1"
    local OUTPUT_FILE="$2"
    local APPEND_MODE="${3:-0}"
    local TEMP_FILE="${OUTPUT_FILE}.suppress.tmp"
    local TEMP_FILE2="${OUTPUT_FILE}.suppress2.tmp"

    # =========================================================================
    # PASS 1: Consecutive pattern suppression (existing logic)
    # =========================================================================
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
                # Single line repetition - use range format (first + last timestamp only)
                ts_first = timestamps[i + 1]
                ts_last = timestamps[i + rep_count - 1]
                print lines[i] " [suppressed count: " (rep_count - 1) ", timestamps: [" ts_first "] to [" ts_last "]]"
                i += rep_count
                found = 1
            }
        }

        # If not single line repetition, try multi-line patterns (2 lines up to N lines)
        if (!found) {
            max_pattern_len = 20
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
