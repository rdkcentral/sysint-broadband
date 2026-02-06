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

echo_t() {
    echo "$(date +"%y%m%d-%T.%6N") $1"
}

APPARMOR_LOG_FILE="/rdklogs/logs/apparmor.txt"
current_time=0
lastync_time=0
BootupLog_is_updated=0

CRON_INSTALLED_FLAG="/tmp/rdklogger_cron_installed"
CONSOLE_LOG_FILE="/rdklogs/logs/Consolelog.txt.0"

# Single iteration of journal log update logic
do_journal_iteration() {
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
           uptime_in_secs=$(cut -d. -f1 /proc/uptime)
           if [ $uptime_in_secs -ge 240 ]  && [ $BootupLog_is_updated -eq 0 ]; then
                nice -n 19 journalctl > ${journal_log}
                BootupLog_is_updated=1;
           fi
   fi
}

install_cron_entry() {
    if [ "$BOX_TYPE" = "XB6" -a "$MANUFACTURE" = "Arris" ]; then
        dmesgsyncinterval_sec=60
        cron="* * * * *"
    else
        dmesgsyncinterval_sec="$(syscfg get dmesglogsync_interval)"
        case "$dmesgsyncinterval_sec" in
            "60")   cron="* * * * *" ;;
            "300")  cron="*/5 * * * *" ;;
            "600")  cron="*/10 * * * *" ;;
            "900")  cron="*/15 * * * *" ;;
            "3600") cron="0 * * * *" ;;
            *)    cron="*/15 * * * *" ;;  # fallback default
        esac
    fi

	CRON_LINE="$cron /rdklogger/update_journal_log.sh start"
    
    if crontab -l 2>/dev/null | grep -q "update_journal_log.sh"; then
        echo_t "update_journal_log.sh - Cron entry already present" >> "$CONSOLE_LOG_FILE"
        return 0
    fi

    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    rc=$?
    
    if [ $rc -eq 0 ]; then
        echo_t "update_journal_log.sh - Cron installed cleanly: $CRON_LINE" >> "$CONSOLE_LOG_FILE"
    else
        echo_t "update_journal_log.sh - Cron install failed (rc=$rc)" >> "$CONSOLE_LOG_FILE"
    fi
}

# Service mode: Infinite loop
service_mode() {
    echo_t "update_journal_log.sh - Running in SERVICE mode (infinite loop)" >> "$CONSOLE_LOG_FILE"

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
if [ "$rdklogger_cron_enable" = "true" ]; then
    echo_t "Cron mode detected - update_journal_log.sh" >> "$CONSOLE_LOG_FILE"
	
    if [ ! -f "$CRON_INSTALLED_FLAG" ]; then
        echo_t "SERVICE: Installing cron (first run) - update_journal_log.sh" >> "$CONSOLE_LOG_FILE"
        install_cron_entry
        touch "$CRON_INSTALLED_FLAG"
	    do_journal_iteration
		
		if [ -f /lib/systemd/system/log_journalmsg.service ]; then
            echo_t "Disabling log_journalmsg.service for cron mode" >> "$CONSOLE_LOG_FILE"
            systemctl stop log_journalmsg.service
        fi
        exit 0
    else
        echo_t "Cron mode active - update_journal_log.sh" >> "$CONSOLE_LOG_FILE"
        do_journal_iteration
        exit 0
    fi
else
	echo_t "Cron disabled - starting service mode - update_journal_log.sh" >> "$CONSOLE_LOG_FILE"
    service_mode
fi
