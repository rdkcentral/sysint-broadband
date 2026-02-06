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

#journalctl
JOURNAL_RUNTIME_DIR="/run/systemd/journald.conf.d"
JOURNAL_OVERRIDE_FILE="${JOURNAL_RUNTIME_DIR}/override.conf"

while [ 1 ]
do
   #journalctl
   uptime_in_secs=$(cut -d. -f1 /proc/uptime)
   if [ "$uptime_in_secs" -ge 1800 ] && [ ! -f "$JOURNAL_OVERRIDE_FILE" ]; then
       mkdir -p "$JOURNAL_RUNTIME_DIR"
       cat > "$JOURNAL_OVERRIDE_FILE" <<'EOF'
[Journal]
RuntimeMaxUse=8M
RuntimeMaxFileSize=4M
RuntimeMaxFiles=2
EOF
       systemctl restart systemd-journald 2>/dev/null || true
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
   # ARRISXB6-8252   sleep for 60 sec until we populate journalctl
   if [ "$BOX_TYPE" = "XB6" -a "$MANUFACTURE" = "Arris" ];then
     dmesgsyncinterval=60
   else
     dmesgsyncinterval=`syscfg get dmesglogsync_interval`
   fi

   sleep $dmesgsyncinterval

done