#!/bin/sh
##########################################################################
# log_suppress_test_generator.sh
# Generates flooded log lines to verify log_suppress.sh behavior.
# No dependencies. Runs indefinitely until killed.
# Usage: sh log_suppress_test_generator.sh [output_log_file]
##########################################################################

LOG_FILE="${1:-/rdklogs/logs/log_suppress_test.txt}"
CYCLE=0

LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR" 2>/dev/null

timestamp() {
    date '+%y%m%d-%H:%M:%S'
}

cleanup() {
    echo "$(timestamp) LOG_SUPPRESS_TEST: Generator stopped after $CYCLE cycles pid=$$" >> "$LOG_FILE"
    exit 0
}

trap cleanup INT TERM

echo "$(timestamp) LOG_SUPPRESS_TEST: Generator started pid=$$ output=$LOG_FILE" >> "$LOG_FILE"

while true; do
    TS=$(timestamp)

    # Unique lines (should never be suppressed)
    echo "$TS CcspWifiSsp: RDKB_CONNECTED_CLIENTS: Client connected MAC=AA:BB:CC:DD:EE:$((CYCLE % 100)) RSSI=-$((40 + CYCLE % 30))" >> "$LOG_FILE"
    echo "$TS PAM: mem_free=$(awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null)kB cpu_load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" >> "$LOG_FILE"

    # Flood: 30 identical lines (should be suppressed to 2 + marker)
    i=0
    while [ "$i" -lt 30 ]; do
        echo "$TS CcspTr069Pa: CURL failed with error 28: Connection timed out after 30000 milliseconds" >> "$LOG_FILE"
        i=$((i + 1))
    done

    # Another flood: 15 identical lines
    i=0
    while [ "$i" -lt 15 ]; do
        echo "$TS CcspCMAgentSsp: DOCSIS CM STATUS: Downstream channel lock failed - no signal" >> "$LOG_FILE"
        i=$((i + 1))
    done

    # 2 identical lines (below threshold - should NOT be suppressed)
    echo "$TS webpa: Ping to parodus failed, retrying" >> "$LOG_FILE"
    echo "$TS webpa: Ping to parodus failed, retrying" >> "$LOG_FILE"

    # 3 identical lines (exactly at threshold)
    echo "$TS PSM: Saving config to persistent storage" >> "$LOG_FILE"
    echo "$TS PSM: Saving config to persistent storage" >> "$LOG_FILE"
    echo "$TS PSM: Saving config to persistent storage" >> "$LOG_FILE"

    # Alternating lines (same message broken by unique - should NOT suppress)
    i=0
    while [ "$i" -lt 5 ]; do
        echo "$TS XDNS: DNS query timeout for host telemetry.xfinity.com" >> "$LOG_FILE"
        echo "$TS XDNS: Resolved telemetry.xfinity.com -> 96.118.$((i + CYCLE % 50)).$((CYCLE % 255))" >> "$LOG_FILE"
        i=$((i + 1))
    done

    # Large flood: 100 identical lines every 5th cycle
    if [ $((CYCLE % 5)) -eq 0 ] && [ "$CYCLE" -gt 0 ]; then
        i=0
        while [ "$i" -lt 100 ]; do
            echo "$TS CcspMoCA: MoCA link down - no peers detected on network" >> "$LOG_FILE"
            i=$((i + 1))
        done
    fi

    CYCLE=$((CYCLE + 1))
    sleep 10
done
