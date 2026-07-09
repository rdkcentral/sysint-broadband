#!/bin/sh
##########################################################################
# log_suppress_test_generator.sh
# Generates sporadic, periodic, and burst-flood log patterns for
# verifying log_suppress.sh behavior on device.
# Installed with sysint-broadband; runs independently, no dependencies.
# Usage: sh log_suppress_test_generator.sh [output_log_file]
# Runs indefinitely until killed.
##########################################################################

LOG_FILE="${1:-/rdklogs/logs/log_suppress_test.txt}"
CYCLE=0

LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR" 2>/dev/null

timestamp() {
    date '+%y%m%d-%H:%M:%S'
}

# Sporadic: unique lines at random intervals (should NOT be suppressed)
sporadic_log() {
    CYCLE=$((CYCLE + 1))
    echo "$(timestamp) [SPORADIC] Unique event #${CYCLE} pid=$$ uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" >> "$LOG_FILE"
}

# Periodic: same format but unique data each time (should NOT be suppressed)
periodic_log() {
    echo "$(timestamp) [PERIODIC] Health check OK - memory_free=$(awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null)kB" >> "$LOG_FILE"
}

# Burst flood: identical lines rapidly repeated (SHOULD be suppressed)
burst_flood() {
    COUNT="${1:-20}"
    MSG="$(timestamp) [BURST] REPEATED: Connection retry failed, endpoint unreachable"
    i=0
    while [ "$i" -lt "$COUNT" ]; do
        echo "$MSG" >> "$LOG_FILE"
        i=$((i + 1))
    done
    echo "$(timestamp) [BURST] Flood of $COUNT identical lines complete" >> "$LOG_FILE"
}

# Mixed burst: two different repeated messages back-to-back (tests pattern boundary)
mixed_burst() {
    i=0
    while [ "$i" -lt 8 ]; do
        echo "$(timestamp) [MIXED] WARNING: DNS lookup timeout for host xconf.xcal.tv" >> "$LOG_FILE"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt 12 ]; do
        echo "$(timestamp) [MIXED] ERROR: CURL returned code 28 - operation timed out" >> "$LOG_FILE"
        i=$((i + 1))
    done
}

# Graduated burst: increasing run lengths to test suppression threshold
graduated_burst() {
    # 2 identical lines (below threshold - should NOT suppress)
    echo "$(timestamp) [GRAD] Level-2 repeat A" >> "$LOG_FILE"
    echo "$(timestamp) [GRAD] Level-2 repeat A" >> "$LOG_FILE"

    # 3 identical lines (at threshold - should suppress 1)
    echo "$(timestamp) [GRAD] Level-3 repeat B" >> "$LOG_FILE"
    echo "$(timestamp) [GRAD] Level-3 repeat B" >> "$LOG_FILE"
    echo "$(timestamp) [GRAD] Level-3 repeat B" >> "$LOG_FILE"

    # 5 identical lines (should suppress 3)
    j=0
    while [ "$j" -lt 5 ]; do
        echo "$(timestamp) [GRAD] Level-5 repeat C" >> "$LOG_FILE"
        j=$((j + 1))
    done

    # 50 identical lines (should suppress 48)
    j=0
    while [ "$j" -lt 50 ]; do
        echo "$(timestamp) [GRAD] Level-50 repeat D" >> "$LOG_FILE"
        j=$((j + 1))
    done
}

# Interleaved: repeated lines with unique lines mixed in (should NOT suppress)
interleaved_log() {
    i=0
    while [ "$i" -lt 6 ]; do
        echo "$(timestamp) [INTERLEAVE] Retry attempt" >> "$LOG_FILE"
        echo "$(timestamp) [INTERLEAVE] Unique marker $i cycle=$CYCLE" >> "$LOG_FILE"
        i=$((i + 1))
    done
}

cleanup() {
    echo "$(timestamp) [GENERATOR] Shutting down after $CYCLE cycles, pid=$$" >> "$LOG_FILE"
    exit 0
}

trap cleanup INT TERM

echo "$(timestamp) [GENERATOR] Started pid=$$ output=$LOG_FILE" >> "$LOG_FILE"

# Main loop
while true; do
    # Periodic: every cycle (10s)
    periodic_log

    # Sporadic: ~30% chance each cycle
    RAND=$(( $(date +%S) * $$ % 100 ))
    if [ "$RAND" -lt 30 ]; then
        sporadic_log
    fi

    # Burst flood (25 lines): every 6th cycle (~60s)
    if [ $((CYCLE % 6)) -eq 0 ] && [ "$CYCLE" -gt 0 ]; then
        burst_flood 25
    fi

    # Mixed burst: every 10th cycle (~100s)
    if [ $((CYCLE % 10)) -eq 0 ] && [ "$CYCLE" -gt 0 ]; then
        mixed_burst
    fi

    # Graduated burst: every 15th cycle (~150s)
    if [ $((CYCLE % 15)) -eq 0 ] && [ "$CYCLE" -gt 0 ]; then
        graduated_burst
    fi

    # Interleaved (no suppression expected): every 12th cycle (~120s)
    if [ $((CYCLE % 12)) -eq 0 ] && [ "$CYCLE" -gt 0 ]; then
        interleaved_log
    fi

    CYCLE=$((CYCLE + 1))
    sleep 10
done
