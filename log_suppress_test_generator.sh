#!/bin/sh
##########################################################################
# log_suppress_test_generator.sh
# Floods an existing log file with repeated lines to verify
# log_suppress.sh behavior on device.
# No dependencies. Runs indefinitely until killed.
# Usage: sh log_suppress_test_generator.sh [log_file]
# Default: /rdklogs/logs/agent.txt
##########################################################################

LOG_FILE="${1:-/rdklogs/logs/agent.txt}"
CYCLE=0

timestamp() {
    date '+%y%m%d-%H:%M:%S'
}

cleanup() {
    echo "$(timestamp) LOG_SUPPRESS_TEST: Generator stopped after $CYCLE cycles pid=$$" >> "$LOG_FILE"
    exit 0
}

trap cleanup INT TERM

echo "$(timestamp) LOG_SUPPRESS_TEST: Generator started pid=$$ target=$LOG_FILE" >> "$LOG_FILE"

while true; do
    TS=$(timestamp)

    # Unique lines (should never be suppressed)
    echo "$TS CcspWifiSsp: RDKB_CONNECTED_CLIENTS: Client connected MAC=AA:BB:CC:DD:EE:$((CYCLE % 100)) RSSI=-$((40 + CYCLE % 30))" >> "$LOG_FILE"

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
