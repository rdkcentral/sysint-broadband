#!/bin/sh
####################################################################################
# If not stated otherwise in this file or this component's Licenses.txt file the
# following copyright and licenses apply:
#
#  Copyright 2018 RDK Management
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
##################################################################################
#update dmesg log into rdklogs/logs/messages.txt

. /etc/device.properties
. /etc/utopia/service.d/log_env_var.sh

APPARMOR_LOG_FILE="/rdklogs/logs/apparmor.txt"
current_time=0
lastync_time=0
BootupLog_is_updated=0

JOURNAL_RUNTIME_DIR="/run/systemd/journald.conf.d"
JOURNAL_OVERRIDE_FILE="${JOURNAL_RUNTIME_DIR}/override.conf"
LOG_FILE="/rdklogs/logs/Consolelog.txt.0"

RDKLOGGER_EXECUTION_MODE="/tmp/.rdklogger_execution_mode"

echo_t()
{
        echo "$(date +"%y%m%d-%T.%6N") $*" >> "$LOG_FILE"
}

JOURNAL_CRON_INSTALLED="/tmp/.journal_log_cron_flag"

do_journal_iteration()
{
   uptime_in_secs=$(cut -d. -f1 /proc/uptime)
   if [ "$uptime_in_secs" -ge 1800 ] && [ ! -f "$JOURNAL_OVERRIDE_FILE" ]; then
       echo_t "Applying journald runtime override"
       mkdir -p "$JOURNAL_RUNTIME_DIR"
       cat > "$JOURNAL_OVERRIDE_FILE" <<'EOF'
[Journal]
RuntimeMaxUse=8M
RuntimeMaxFileSize=4M
RuntimeMaxFiles=2
EOF
       if [ $? -ne 0 ]; then
           echo_t "ERROR: Failed to create journald override file"
       fi
       systemctl restart systemd-journald >/dev/null 2>&1
       rc=$?

       if [ $rc -ne 0 ]; then
           echo_t "ERROR: systemd-journald restart failed, rc=$rc"
       else
           echo_t "journald runtime threshold set to 8MB successfully"
       fi
   fi
   current_time=$(date +%s)
   if [ -f "$lastdmesgsync" ];then
   	lastsync_time=`cat $lastdmesgsync`
   fi
   
   difference_time=$(( current_time - lastsync_time ))
   lastsync_time=$current_time
   echo "$current_time" > $lastdmesgsync
   
   #Keeps appending to the existing file 
   nice -n 19 journalctl -k --since "${difference_time} sec ago" >> ${DMESG_FILE}
   cat ${DMESG_FILE} | grep -i "apparmor" > ${APPARMOR_LOG_FILE}
   if [ "$BOX_TYPE" = "XB6" ] || [ "$BOX_TYPE" = "XF3" ] || [ "$BOX_TYPE" = "TCCBR" ] || [ "$BOX_TYPE" == "VNTXER5" ] || [ "$BOX_TYPE" == "SCER11BEL" ] || [ "$BOX_TYPE" == "SCXF11BFL" ];then
	   #ARRISXB6-7973: Complete journalctl logs to /rdklogs/logs/journal_logs.txt.0
           if [ $uptime_in_secs -ge 240 ]  && [ $BootupLog_is_updated -eq 0 ]; then
                nice -n 19 journalctl > ${journal_log}
                BootupLog_is_updated=1;
           fi
   fi
}

install_cron_entry() {
    if [ "$BOX_TYPE" = "XB6" -a "$MANUFACTURE" = "Arris" ]; then
        dmesgsyncinterval_sec=60
    else
        dmesgsyncinterval_sec="$(syscfg get dmesglogsync_interval)"
    fi

    [ -z "$dmesgsyncinterval_sec" ] && dmesgsyncinterval_sec=900

    interval_min=$((dmesgsyncinterval_sec / 60))

    if [ "$interval_min" -le 1 ]; then
        cron="* * * * *"
    elif [ "$interval_min" -ge 60 ]; then
        cron="0 * * * *"
    else
        cron="*/$interval_min * * * *"
    fi

	CRON_LINE="$cron /rdklogger/update_journal_log.sh start"
    
    if crontab -l 2>/dev/null | grep -q "update_journal_log.sh"; then
        echo_t "update_journal_log.sh - Cron entry already present"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    rc=$?
    
    if [ $rc -eq 0 ]; then
        echo_t "update_journal_log.sh - Cron installed cleanly: $CRON_LINE"
    else
        echo_t "update_journal_log.sh - Cron install failed (rc=$rc)"
    fi
}

service_mode() {

    while [ 1 ];
    do
        do_journal_iteration
        # ARRISXB6-8252   sleep for 60 sec until we populate journalctl
        if [ "$BOX_TYPE" = "XB6" -a "$MANUFACTURE" = "Arris" ];then
           dmesgsyncinterval=60
        else
           dmesgsyncinterval=`syscfg get dmesglogsync_interval`
        fi

       sleep $dmesgsyncinterval

    done
}

rdklogger_cron_enable=`syscfg get RdkbLogCronEnable`

if [ ! -f "$RDKLOGGER_EXECUTION_MODE" ]; then
    if [ "$rdklogger_cron_enable" = "true" ]; then
        echo "cron" > "$RDKLOGGER_EXECUTION_MODE"
    else
        echo "process" > "$RDKLOGGER_EXECUTION_MODE"
    fi
fi

execution_mode=$(cat "$RDKLOGGER_EXECUTION_MODE")

if [ "$execution_mode" = "cron" ]; then
	
    if [ ! -f "$JOURNAL_CRON_INSTALLED" ]; then
        install_cron_entry
        touch "$JOURNAL_CRON_INSTALLED"
	    do_journal_iteration
		
		if [ -f /lib/systemd/system/log_journalmsg.service ]; then
            systemctl stop log_journalmsg.service
        fi
        exit 0
    else
        do_journal_iteration
        exit 0
    fi
else
    service_mode
fi
