#!/bin/sh

. /etc/include.properties
. /etc/device.properties

if [ -f /lib/rdk/t2Shared_api.sh ]; then
      source /lib/rdk/t2Shared_api.sh
fi

# Log file
if [ -z "$NTPD_LOG_NAME" ]; then
    NTPD_LOG_NAME=/rdklogs/logs/ntpLog.log
fi

DEBUG_INTERVAL=120      
TELEMETRY_INTERVAL=14400 

send_to_telemetry() {
    metrics_line="$1"
    DELAY=$(echo "$metrics_line" | awk '{print $(NF-2)}')
    OFFSET=$(echo "$metrics_line" | awk '{print $(NF-1)}')
    JITTER=$(echo "$metrics_line" | awk '{print $NF}')

    echo "$(date) Sending NTP metrics to telemetry: Delay=$DELAY Offset=$OFFSET Jitter=$JITTER" >> $NTPD_LOG_NAME
    t2ValNotify "SYS_INFO_NTPDELAY_split" "$DELAY"

}

log_debug_info() {
    echo "========== $(date) ==========" >> $NTPD_LOG_NAME
    ntpq -p >> $NTPD_LOG_NAME
}

while true; do
    metrics_line=$(ntpq -p | awk 'NR > 2 && $1 ~ /^\*/ { print; exit }')

    if [ -z "$metrics_line" ]; then
        # No sync - debug log every 2 minutes
        echo "$(date) No active NTP peer found." >> $NTPD_LOG_NAME
        log_debug_info
        sleep $DEBUG_INTERVAL
    else
        # In sync - send telemetry every 4 hours
        send_to_telemetry "$metrics_line"
        sleep $TELEMETRY_INTERVAL
    fi
done



