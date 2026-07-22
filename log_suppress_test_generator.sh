#!/bin/sh
##########################################################################
# log_suppress_test_generator.sh
# Test tool: floods /rdklogs/logs/messages.txt with repeated lines
# to verify log_suppress.sh behavior on device.
#
# Runs independently of log suppression pipeline.
#
# Start: touch /tmp/.log_suppress_test && sh /lib/rdk/log_suppress_test_generator.sh &
# Stop:  rm /tmp/.log_suppress_test
#
# The script checks for the trigger file each cycle and exits when removed.
# Can be launched at boot from /etc/cron.d or any init hook.
##########################################################################

TRIGGER_FILE="/tmp/.log_suppress_test"
LOG_FILE="/rdklogs/logs/messages.txt"
PID_FILE="/tmp/.log_suppress_test_generator.pid"

# Exit if trigger file doesn't exist
if [ ! -f "$TRIGGER_FILE" ]; then
    exit 0
fi

# Exit if already running
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi

# Record PID
echo $$ > "$PID_FILE"

timestamp() {
    date '+%y%m%d-%H:%M:%S'
}

cleanup() {
    echo "$(timestamp) LOG_SUPPRESS_TEST: Generator stopped after $CYCLE cycles pid=$$" >> "$LOG_FILE"
    rm -f "$PID_FILE"
    exit 0
}

trap cleanup INT TERM

CYCLE=0
echo "$(timestamp) LOG_SUPPRESS_TEST: Generator started pid=$$ target=$LOG_FILE" >> "$LOG_FILE"

while [ -f "$TRIGGER_FILE" ]; do
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

cleanup
