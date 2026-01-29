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
RDK_LOGGER_PATH="/rdklogger"

source /etc/device.properties
source /etc/utopia/service.d/log_capture_path.sh
source /lib/rdk/utils.sh
if [ -f /etc/logFiles.properties ]; then
    source /etc/logFiles.properties
fi

if [ -f /etc/telemetry2_0.properties ]; then
    . /etc/telemetry2_0.properties
fi

source /lib/rdk/t2Shared_api.sh

#. $RDK_LOGGER_PATH/commonUtils.sh
MAINTENANCE_WINDOW="/tmp/maint_upload"
PATTERN_FILE="/tmp/pattern_file"
SCP_RUNNING="/tmp/scp_running"
SCP_WAITING="/tmp/scp_waiting"

SCP_COMPLETE="/tmp/.scp_done"

PEER_COMM_ID="/tmp/elxrretyt-logf.swr"
if [ -f /etc/ONBOARD_LOGGING_ENABLE ]; then
    ONBOARDLOGS_NVRAM_BACKUP_PATH="/nvram2/onboardlogs/"
    ONBOARDLOGS_TMP_BACKUP_PATH="/tmp/onboardlogs/"
fi

if [ ! -f /usr/bin/GetConfigFile ];then
    echo "Error: GetConfigFile Not Found"
    exit 127
fi

PRESERVE_LOG_PATH="$LOG_SYNC_PATH/../preserveLogs/"

IDLE_TIMEOUT=30
TELEMETRY_INOTIFY_FOLDER=/telemetry
TELEMETRY_INOTIFY_EVENT="$TELEMETRY_INOTIFY_FOLDER/eventType.cmd"

DCA_COMPLETED="/tmp/.dca_done"
PING_PATH="/usr/sbin"
ARM_LOGS_NVRAM2="/nvram2/logs/ArmConsolelog.txt.0"

MAC=`getMacAddressOnly`
HOST_IP=`getIPAddress`
dt=`date "+%m-%d-%y-%I-%M%p"`
LOG_FILE=$MAC"_Logs_$dt.tgz"

FLUSH_LOG_PATH="/rdklogger/flush_logs.sh"

SYSCFG_FILE="syscfg.db"
BBHM_CFG_FILE="bbhm_cur_cfg.xml"
WIRELESS_CFG_FILE="wireless"
SE05x_rdk_logs="se05x_daemon.log"
SE05x_tmp_logs="/tmp/rdkssa.txt"

if [ "$BOX_TYPE" = "XB3" ]; then
SYSCFG_DB_FILE="/nvram/syscfg.db"
else
SYSCFG_DB_FILE="/opt/secure/data/syscfg.db"
fi

moveFile()
{        
     if [[ -f "$1" ]]; then mv $1 $2; fi
}
 
moveFiles()
{
# $1 : source folder
# $2 : destination folder

     currentDir=`pwd`
     cd $2
     
     mv $1/* .
     
     cd $currentDir
}

createFiles()
{
	FILES=$LOG_FILES_NAMES
	for f in $FILES
	do
		if [ ! -e $LOGTEMPPATH$f ]
		then
			touch $LOGTEMPPATH$f
		fi
	done
	touch $LOG_FILE_FLAG
}

createSysDescr()
{
	#Create sysdecr value
	echo_t "Get all parameters to create sysDescr..."
	description=`dmcli eRT retv Device.DeviceInfo.Description`
	hwRevision=`dmcli eRT retv Device.DeviceInfo.HardwareVersion`
	vendor=`dmcli eRT retv Device.DeviceInfo.Manufacturer`
	bootloader=`dmcli eRT retv Device.DeviceInfo.X_CISCO_COM_BootloaderVersion`

	adswVersion=`dmcli eRT retv Device.DeviceInfo.AdditionalSoftwareVersion`
	swVersion=`dmcli eRT retv Device.DeviceInfo.SoftwareVersion`
	sw_fw_version="$adswVersion"_"$swVersion"

	modelName=`dmcli eRT retv Device.DeviceInfo.ModelName`
	echo_t "RDKB_SYSDESCR : $description HW_REV: $hwRevision; VENDOR: $vendor; BOOTR: $bootloader; SW_REV: $sw_fw_version; MODEL: $modelName "
	
}

flush_atom_logs()
{
    T2_ENABLE=`syscfg get T2Enable` 
    if [ ! -f $T2_0_BIN ]; then                                             
    	echo_t  "Unable to find $T2_0_BIN ... Switching T2 Enable to false !!!"
    	T2_ENABLE="false"                 
    fi
    echo_t "[DEBUG] ++IN Function flush_atom_logs" >> /rdklogs/logs/telemetry2_0.txt.0
    echo_t "[DEBUG] ++IN Function flush_atom_logs"

    cp $LOG_SYNC_PATH/$SelfHealBootUpLogFile $LOG_PATH
    cp $LOG_SYNC_PATH$PcdLogFile $LOG_PATH

    if [ "x$T2_ENABLE" == "xtrue" ]; then  
    	echo_t  "[DEBUG] $0 Notify telemetry to execute now before log upload !!!" >> /rdklogs/logs/telemetry2_0.txt.0
    	echo_t  "[DEBUG] $0 Notify telemetry to execute now before log upload !!!"
        sh /lib/rdk/dca_utility.sh 2 &
    else
        GetConfigFile $PEER_COMM_ID stdout | ssh -I $IDLE_TIMEOUT -i /dev/stdin root@$ATOM_INTERFACE_IP "/bin/echo 'execTelemetry' > $TELEMETRY_INOTIFY_EVENT" > /dev/null 2>&1
    fi
 	local loop=0
	while :
	do
		sleep 10
		loop=$((loop+1))
		if [ -f "$DCA_COMPLETED" ] || [ "$loop" -ge "6" ]
		then
			# Remove the contents of ATOM side log files.
		     echo_t "[DEBUG] telemetry operation completed loop count = $loop" >> /rdklogs/logs/telemetry2_0.txt.0
		     echo_t "[DEBUG] telemetry operation completed loop count = $loop"
                     echo_t "DCA completed or wait for 60 sec is over, flushing ATOM logs"
                        atom_log_flush=`rpcclient  $ATOM_ARPING_IP "$FLUSH_LOG_PATH"`
			atom_log_flush_output=`echo "$atom_log_flush" | grep "RPC CONNECTED"`
			if [ "$atom_log_flush_output" = "" ];then
                     	echo_t "rpcclient failed, setting FlushAllLogs TR-181 to flush atom side logs"
		       	 dmcli eRT setv Device.Logging.FlushAllLogs bool true 
                        fi
			rm -rf $DCA_COMPLETED	
			break
		fi

	done
    echo_t "[DEBUG] --OUT Function flush_atom_logs" >> /rdklogs/logs/telemetry2_0.txt.0
    echo_t "[DEBUG] --OUT Function flush_atom_logs"
}

#To sync logs from atom side :
#If there is no scp running then it should do the file transfer.
# If some process try to execute when another scp operation is in progress,
# it will wait for 60 sec, then it will forcefully kill the scp process if it still exists.
sync_atom_log_files()
{
    destination=$1
    SCP_PID=`pidof scp`
    if [ ! -f $PEER_COMM_ID ]; then
        GetConfigFile $PEER_COMM_ID
    fi
    if [ "$SCP_PID" != "" ] && [ -f $SCP_RUNNING ] && [ ! -f $SCP_WAITING ]; then
        i=0;
        timeout=1;
        echo_t "Already scp running pid=$SCP_PID"
        touch $SCP_WAITING
        while [ $i -le 60 ]; do
            SCP_PID=`pidof scp`
            if [ "$SCP_PID" == "" ]; then
                timeout=0
                echo_t "existing scp process finished"
                break
            fi
            i=$((i + 1))
            sleep 1
        done

        if [ $timeout -eq 1 ]; then
            echo_t "killing all scp"
            killall scp
        fi

        if [ -f $SCP_RUNNING ]; then
            rm $SCP_RUNNING
        fi
            scp -i $PEER_COMM_ID -r root@$ATOM_IP:$ATOM_LOG_PATH$ATOM_FILE_LIST $destination > /dev/null 2>&1
        sync_res=$?
        if [ "$sync_res" = "0" ]; then
            echo "Sync from ATOM complete"
        else
            echo "Sync from ATOM failed , return code is $sync_res"
        fi

        if [ -f $SCP_WAITING ]; then
            rm $SCP_WAITING
        fi
    elif [ "$SCP_PID" == "" ]; then
        touch $SCP_RUNNING
            scp -i $PEER_COMM_ID -r root@$ATOM_IP:$ATOM_LOG_PATH$ATOM_FILE_LIST $destination > /dev/null 2>&1
        sync_res=$?
        if [ "$sync_res" = "0" ]; then
            echo "Sync from ATOM complete"
        else
            echo "Sync from ATOM failed , return code is $sync_res"
        fi
        rm $SCP_RUNNING
    fi
}

log_file_update_modify_time()
{
    log_file=$1
    option=$2

    if [ "$MODEL_NUM" = "CGA4332COM" ] && [ "$option" = "reboot" ]; then
        return
    fi

    modify_time=`stat -c %Y $LOG_PATH$log_file`
    # set last modification time to the first line of the file
    if [ "$BOX_TYPE" = "SR213" ] && [ "$option" = "reboot" ]; then
        awk 'NR==1{$0=$modify_time}1' $LOG_SYNC_PATH$log_file  > $LOG_SYNC_PATH/temp.txt;mv $LOG_SYNC_PATH/temp.txt $LOG_SYNC_PATH$log_file
    else
        sed -i "1s/.*/$modify_time/" $LOG_SYNC_PATH$log_file
    fi
}


log_file_update_offset()
{
    log_file=$1
    option=$2

    if [ "$MODEL_NUM" = "CGA4332COM" ] && [ "$option" = "reboot" ]; then
        return
    fi

    next_offset=`wc -l $LOG_SYNC_PATH$log_file | cut -d " " -f1`
    # set next offset to the first line of the file
    if [ "$BOX_TYPE" = "SR213" ] && [ "$option" = "reboot" ]; then
        awk 'NR==1{$0=$next_offset}1' $LOG_SYNC_PATH$log_file  > $LOG_SYNC_PATH/temp.txt;mv $LOG_SYNC_PATH/temp.txt $LOG_SYNC_PATH$log_file
    else
        sed -i "1s/.*/$next_offset/" "$LOG_SYNC_PATH$log_file"
    fi
}


log_file_append_logs()
{
    log_file=$1
    curr_offset=$2
    # appending the logs to nvram2 starting from the offset
    tail -n +$curr_offset $LOG_PATH$log_file >> $LOG_SYNC_PATH$log_file
}


log_file_is_rollover_occured()
{
    log_file=$1

    cur_modify_time=`stat -c %Y $LOG_PATH$log_file`
#    prev_modify_time=`sed -n '1p' $LOG_SYNC_PATH$log_file`
    prev_modify_time=`head -n 1 $LOG_SYNC_PATH$log_file`

    if [ "$cur_modify_time" != "$prev_modify_time" ]; then
        true
    else
        false
    fi
}


is_numeral()
{
    what=$1

    echo "$what" | grep "^[0-9]*$" > /dev/null
    is_numeral="$?"

    if [ ! -z $what ] && [ $is_numeral = 0 ]; then
        true
    else
        false
    fi
}


log_files_sync_to_nvram2()
{
    option=$1
    default_offset="1"

    # Get all unique filenames without numeric suffixes, f.e MWO.log, wifiMgr.txt, etc
    module_log_basenames=`ls $LOG_PATH | sed 's/\.[0-9]*$//' | sort -u`

    for module_log_basename in $module_log_basenames
    do
        module_log_files=`ls $LOG_PATH | grep "^$module_log_basename"`
        for log_file in $module_log_files
        do
            if [ ! -f $LOG_SYNC_PATH$log_file ]; then
                echo $default_offset > $LOG_SYNC_PATH$log_file
            fi
        done

        main_log_file=`echo $module_log_files | awk '{print $1}'`
        rollover_log_file=`echo $module_log_files | awk '{print $2}'`

        if [ ! -z $rollover_log_file ]; then
            if log_file_is_rollover_occured $rollover_log_file; then
                log_file_append_logs $rollover_log_file $default_offset
                log_file_update_modify_time $rollover_log_file $option
                # clear main .0 log file to write new logs after rollover
                echo $default_offset > $LOG_SYNC_PATH$main_log_file
            fi
        fi

        if [ "$BOX_TYPE" = "SR213" ] && [ "$option" = "reboot" ]; then
            offset=`head -n 1 $LOG_SYNC_PATH$main_log_file`
        else
            offset=`sed -n '1p' $LOG_SYNC_PATH$main_log_file`
        fi
        #PART of ARRISXB6-11061, to have numeral and null check for offset
        if ! is_numeral $offset; then
            continue
        fi

        log_file_append_logs $main_log_file $offset
        log_file_update_offset $main_log_file $option

    done
}

syncLogs_nvram2()
{
    option=$1

    echo_t "sync logs to nvram2"
    if [ ! -d "$LOG_SYNC_PATH" ]; then
        #echo "making sync dir"
        mkdir -p $LOG_SYNC_PATH
    fi

    #Arris Proposed RDKB Generic Bug Fix from XB6
    #cleanup any old temporary sed files, dont let them accumulate
    rm -f $LOG_SYNC_PATH/sed*

    # Sync ATOM side logs in /nvram2/logs/ folder
    if [ "$ATOM_SYNC" = "yes" ]; then
        echo_t "Check whether ATOM ip accessible before syncing ATOM side logs"
        if [ -f $PING_PATH/ping_peer ]; then

            PING_RES=`ping_peer`
            CHECK_PING_RES=`echo $PING_RES | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1`

            if [ "$CHECK_PING_RES" != "" ]; then
                if [ "$CHECK_PING_RES" != "100" ]; then
                    echo_t "Ping to ATOM ip success, syncing ATOM side logs"
                    sync_atom_log_files $LOG_PATH
                else
                    echo_t "Ping to ATOM ip falied, not syncing ATOM side logs"
                fi
            else
                echo_t "Ping to ATOM ip falied, not syncing ATOM side logs"
            fi
        fi
    fi

    if [ "$BOX_TYPE" == "XB6" ] || [ "$BOX_TYPE" == "XF3" ] || [ "$BOX_TYPE" == "TCCBR" ] ||  [ "$BOX_TYPE" == "VNTXER5" ]; then
        current_time=$(date +%s)
        if [ -f "$lastdmesgsync" ]; then
            lastsync_time=`cat $lastdmesgsync`
        else
            lastsync_time=0
        fi
        difference_time=$(( current_time - lastsync_time ))
        # lastsync_time=$current_time
        echo "$current_time" > $lastdmesgsync
        nice -n 19 journalctl -k --since "${difference_time} sec ago" >> ${DMESG_FILE}
    fi

    log_files_sync_to_nvram2 $option

    if [ -f /tmp/backup_onboardlogs ]; then
        backup_onboarding_logs
    fi
}

CopyToTmp()
{
	if [ ! -d $TMP_UPLOAD ]; then
	#echo "making directory"
	mkdir -p $TMP_UPLOAD 
    fi
	file_list=`ls $LOG_SYNC_BACK_UP_PATH`

    for file in $file_list
    do
	cp $LOG_SYNC_BACK_UP_PATH$file $TMP_UPLOAD # Copying all log files directly
    done
	rm -rf $LOG_SYNC_BACK_UP_PATH*.txt*
	rm -rf $LOG_SYNC_BACK_UP_PATH*.log*
	rm -rf $LOG_SYNC_BACK_UP_PATH*core*
	rm -rf $LOG_SYNC_BACK_UP_PATH*.bin*
	if [ "$BOX_TYPE" == "HUB4" ]; then
		rm -rf $LOG_SYNC_BACK_UP_PATH*tar.gz*
	fi
	rm -rf $LOG_SYNC_BACK_UP_PATH$PcdLogFile
	if [ "$BOX_TYPE" = "XB6" ]; then
		rm -rf $LOG_SYNC_BACK_UP_PATH$SYSCFG_FILE
		rm -rf $LOG_SYNC_BACK_UP_PATH$BBHM_CFG_FILE
		rm -rf $LOG_SYNC_BACK_UP_PATH$WIRELESS_CFG_FILE
	fi
}
checkConnectivityAndReboot()
{
	rebootNeeded=0
	uptime=$(cut -d. -f1 /proc/uptime)
	if [ "$uptime" -ge "1800" ] ; then
		#echo "box is up more than 30 min"
		rebootNeeded=1

		date | grep 1970
		if [ $? -eq 0 ] ; then 
			echo_t "time is still not getting synced"
                        rebootNeeded=0
		fi

		ping -c 2 google.com >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "ping to google failed"
		else
			rebootNeeded=0
		fi

		ping6 -c 2 google.com >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "ping6 to google failed"
		else
			rebootNeeded=0
		fi

		ping -c 2 75.75.75.75 >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "ping to 75.75.75.75 failed"
		else
			rebootNeeded=0
		fi

		ping -c 2 8.8.8.8 >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "ping to 8.8.8.8 failed"
		else
			rebootNeeded=0
		fi

		ping6 -c 2 2001:558:feed::1 >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "ping6 to 2001:558:feed::1 failed"
		else
			rebootNeeded=0
		fi
		curl google.com >> /dev/null
		if [ $? -ne 0 ] ; then 
			echo_t "curl failed"
		else
			rebootNeeded=0
		fi
	fi

	if [ $rebootNeeded -eq 1 ] ; then
		echo_t "Connectivity is still not back.. rebooting due to no connectivity"
		t2CountNotify "SYS_ERROR_NoConnectivity_reboot"
		syscfg set X_RDKCENTRAL-COM_LastRebootReason "no-connectivity"
		syscfg set X_RDKCENTRAL-COM_LastRebootCounter 1
		syscfg commit
		sleep 5
		reboot
	else
		echo_t "Connectivity is ok at `date`"
	fi
}

preserveThisLog()
{
	path=$2
	if [ "$path" = "" ] ; then
	  path=$TMP_UPLOAD
	fi
	file=$1
	logBackupEnable=`syscfg get log_backup_enable`
	if [ "$logBackupEnable" = "true" ]; then 
		if [ "$path" != "$PRESERVE_LOG_PATH" ] ; then
			if [ ! -d $PRESERVE_LOG_PATH ] ; then
				mkdir -p $PRESERVE_LOG_PATH
			fi
			
			if [ ! -f /tmp/backupCount ]; then
				if [ -d $PRESERVE_LOG_PATH ] ; then
					backupCount=`ls $PRESERVE_LOG_PATH | grep ".tgz" | wc -l`
					echo $backupCount > /tmp/backupCount
				else
					echo 0 > /tmp/backupCount
				fi
			fi
			backupCount=`cat /tmp/backupCount`
			logThreshold=`syscfg get log_backup_threshold`
                        echo_t "Backed up count: $backupCount and threshold : $logThreshold before copying"
			if [ "$backupCount" -lt "$logThreshold" ]; then
				if [ -f "$path/$file" ] ; then
					if [ ! -f "$PRESERVE_LOG_PATH/$file" ]; then #Avoid duplicate copy
						echo_t  "$path/$file log upload..preserve this log for further analysis"
						cp $path/$file $PRESERVE_LOG_PATH
						echo "Deleting the tar file after copying to $PRESERVE_LOG_PATH"
						rm -rf $path/$file
						backupCount=`expr $backupCount + 1`
						echo $backupCount > /tmp/backupCount
						#ARRISXB6-8631, mitigation to reboot when we dont have connectivity for long time
						model=$MODEL_NUM
					fi
				else
					echo_t "$path/$file not found at path $path"
				fi #if [ -f "$path/$file" ] ; then 
			else
				echo "backupCount reached the logThreshold value , deleting the tar file"
				rm -rf $path/$file
			fi #end of if [ $backupCount -lt ..
			#ARRISXB6-8631, mitigation to reboot when we dont have connectivity for long time
			if [ "$model" = "TG3482G" ]; then
                                wan_status="`sysevent get wan-status`"
                                if [ "$3" != "wan-stopped" ] && [ "$wan_status" != "stopped" ]; then
				        if [ $backupCount -ge 2 ]; then
					        checkConnectivityAndReboot
				        fi #if [ $backupCount -eq ..; 
                                else
                                        echo_t "The wan-stopped case, we shouldn't check for connectivity"
                                fi
			fi #if [ "$model" = "TG3482G" ];
		fi #if [ ! -d $PRESERVE_LOG_PATH ] ; then
	else
		echo "Deleting the tar file since logBackupEnable is disabled"
		rm -rf $path/$file
	fi #if [ "$logBackupEnable" = "true" ];then
}

adjustPreserveCount()
{
    if [ ! -f /tmp/backupCount ]; then
        if [ -d $PRESERVE_LOG_PATH ] ; then
        	backupCount=`ls $PRESERVE_LOG_PATH | grep ".tgz" | wc -l`
                echo $backupCount > /tmp/backupCount
        else
                echo 0 > /tmp/backupCount
	fi
    fi
    backupCount=`cat /tmp/backupCount`

    if [ "$backupCount" -gt "0" ]; then
      backupCount=`expr $backupCount - 1`
      echo $backupCount > /tmp/backupCount
    fi #end of if [ $backupCount -lt ..
}

backupnvram2logs()
{
	destn=$1
	MAC=`getMacAddressOnly`
	dt=`date "+%m-%d-%y-%I-%M%p"`
	workDir=`pwd`

	#createSysDescr
        echo_t "[DEBUG] ++IN function backupnvram2logs"	 >> /rdklogs/logs/telemetry2_0.txt.0
        echo_t "[DEBUG] ++IN function backupnvram2logs"
	if [ ! -d "$destn" ]; then
	   mkdir -p $destn
	else
	   FILE_EXISTS=`ls $destn`
	   if [ "$FILE_EXISTS" != "" ]; then
          	rm -rf $destn*.tgz
	   fi
	fi

        if [ "$ATOM_SYNC" = "yes" ]
        then
                 # Remove the contents of ATOM side log files.
#                dmcli eRT setv Device.Logging.FlushAllLogs bool true
		 echo_t "call dca for log processing and then flush ATOM logs"
		 flush_atom_logs &

		 if [ -f "$SCP_COMPLETE" ]; then
		   rm -rf $SCP_COMPLETE
		 fi

		 local loop=0
		 while :
		 do
			if [ -f "$SCP_COMPLETE" ] || [ "$loop" -ge "3" ]
			then
				echo_t "scp completed or wait for 30 sec is over"
				if [ -f "$SCP_COMPLETE" ]; then
				  rm -rf $SCP_COMPLETE
				fi
				break
			fi
			loop=$((loop+1))
			sleep 10
		 done
        else
		        echo_t  "[DEBUG] $0 Notify telemetry to execute now before log upload !!!" >> /rdklogs/logs/telemetry2_0.txt.0
		        echo_t  "[DEBUG] $0 Notify telemetry to execute now before log upload !!!"
			sh /lib/rdk/dca_utility.sh 2 &
			local loop=0
			while :
			do
				sleep 10
				loop=$((loop+1))
				if [ -f "$DCA_COMPLETED" ] || [ "$loop" -ge 6 ]
				then
					# Remove the contents of ATOM side log files.
					#echo_t "DCA completed or wait for 60 sec is over, flushing ATOM logs"
					#dmcli eRT setv Device.Logging.FlushAllLogs bool true
					echo_t "[DEBUG] telemetry operation completed loop count = $loop" >> /rdklogs/logs/telemetry2_0.txt.0
					echo_t "[DEBUG] telemetry operation completed loop count = $loop"
					rm -rf $DCA_COMPLETED
					break
				fi

			done

        fi

	cd $destn
	cp /version.txt $LOG_SYNC_PATH
        if [ "$MODEL_NUM" = "CGM4981COM" ] || [ "${MODEL_NUM}" = "CGM601TCOM" ] || [ "${MODEL_NUM}" = "SG417DBCT" ] || [ "$MODEL_NUM" == "SR213" ]; then
              cp $SE05x_tmp_logs $LOG_SYNC_PATH$SE05x_rdk_logs
        fi

        if [ "$BOX_TYPE" = "XB6" ]; then
        	cp $SYSCFG_DB_FILE $LOG_SYNC_PATH$SYSCFG_FILE
        	cp /tmp/$BBHM_CFG_FILE $LOG_SYNC_PATH$BBHM_CFG_FILE
        	cp /nvram/config/$WIRELESS_CFG_FILE $LOG_SYNC_PATH$WIRELESS_CFG_FILE
        	sed -i "s/.*passphrase.*/\toption passphrase \'\'/g" $LOG_SYNC_PATH$WIRELESS_CFG_FILE
        fi
	echo "*.tgz" > $PATTERN_FILE # .tgz should be excluded while tar
	wan_event=`sysevent get wan_event_log_upload`
        if [ -f "/tmp/.uploadregularlogs" ] || [ "$wan_event" == "yes" ]
        then
            if [ -f /tmp/backup_onboardlogs ] && [ -f /nvram/.device_onboarded ]; then
                echo "tar activation logs from backupnvram2logs"
                copy_onboardlogs "$LOG_SYNC_PATH"
                tar -X $PATTERN_FILE -cvzf $MAC"_Logs_"$dt"_activation_log.tgz" $LOG_SYNC_PATH
                rm -rf /tmp/backup_onboardlogs
            else
                echo "tar logs from backupnvram2logs"
	            tar -X $PATTERN_FILE -cvzf $MAC"_Logs_$dt.tgz" $LOG_SYNC_PATH
	        fi
        fi

	rm $PATTERN_FILE
	 # Removing ATOM side logs

	rm -rf $LOG_SYNC_PATH*.txt*
	rm -rf $LOG_SYNC_PATH*.log*
	rm -rf $LOG_SYNC_PATH*core*
	rm -rf $LOG_SYNC_PATH*.bin*
	if [ "$BOX_TYPE" == "HUB4" ] || [ "$BOX_TYPE" == "SR300" ] || [ "x$BOX_TYPE" == "xSR213" ] || [ "$BOX_TYPE" == "SE501" ] || [ "$BOX_TYPE" == "WNXL11BWL" ] || [ "$BOX_TYPE" == "SCER11BEL" ] || [ "$BOX_TYPE" == "SCXF11BFL" ]; then
		rm -rf $LOG_SYNC_PATH*tar.gz*
	fi
	rm -rf $LOG_SYNC_PATH$PcdLogFile
	if [ "$BOX_TYPE" = "XB6" ]; then
		rm -rf $LOG_SYNC_PATH$SYSCFG_FILE  
		rm -rf $LOG_SYNC_PATH$BBHM_CFG_FILE
		rm -rf $LOG_SYNC_PATH$WIRELESS_CFG_FILE
	fi

	cd $LOG_PATH
	FILES=`ls`

	for fname in $FILES
	do
		>$fname;
	done

        echo_t "[DEBUG] --OUT function backupnvram2logs" >> /rdklogs/logs/telemetry2_0.txt.0
        echo_t "[DEBUG] --OUT function backupnvram2logs"
	cd $workDir
}

backupnvram2logs_on_reboot()
{
	UploadFile=`ls $LOG_SYNC_BACK_UP_REBOOT_PATH | grep "tgz"`
	if [ "$BOX_TYPE" = "XB3" ]
	then
		if [ ! -d "$TMP_UPLOAD" ]; then
			mkdir -p $TMP_UPLOAD
		fi
		if [ "$UploadFile" != "" ]
		then
			echo_t "RDK_LOGGER: backupnvram2logs_on_reboot moving the tar file to tmp for xb3 "
			mv $LOG_SYNC_BACK_UP_REBOOT_PATH/$UploadFile  $TMP_UPLOAD
		fi
		TarCreatePath=$TMP_UPLOAD

	else
		if [ ! -d $PRESERVE_LOG_PATH ] ; then
			mkdir -p $PRESERVE_LOG_PATH
		fi
		if [ "$UploadFile" != "" ]
		then
			echo_t "RDK_LOGGER: backupnvram2logs_on_reboot moving tar $UploadFile to preserve path for non xb3"
			preserveThisLog $UploadFile $LOG_SYNC_BACK_UP_REBOOT_PATH
		fi
		TarCreatePath=$LOG_SYNC_BACK_UP_PATH
		TarFolder=$LOG_SYNC_PATH
	fi

	destn=$TarCreatePath
	MAC=`getMacAddressOnly`
	dt=`date "+%m-%d-%y-%I-%M%p"`
	workDir=`pwd`

	createSysDescr >> $ARM_LOGS_NVRAM2
	if [ "$BOX_TYPE" = "XB3" ]
	then
		cd $TMP_UPLOAD
		CopyToTmp
		TarFolder=$TMP_UPLOAD
	fi

#	if [ ! -d "$destn" ]; then
#	   mkdir -p $destn
#	else
#	   FILE_EXISTS=`ls $destn`
#	   if [ "$FILE_EXISTS" != "" ]; then
#          	rm -rf $destn*.tgz
#	   fi
#	fi

	cd $destn
	cp /version.txt $LOG_SYNC_PATH
        if [ "$MODEL_NUM" = "CGM4981COM" ] || [ "${MODEL_NUM}" = "CGM601TCOM" ] || [ "${MODEL_NUM}" = "SG417DBCT" ] || [ "${MODEL_NUM}" = "CWA438TCOM" ] || [ "$MODEL_NUM" == "SR213" ]; then		
              cp $SE05x_tmp_logs $TarFolder$SE05x_rdk_logs
        fi

         if [ "$BOX_TYPE" = "XB6" ]; then
        	cp $SYSCFG_DB_FILE $TarFolder$SYSCFG_FILE
        	cp /nvram/$BBHM_CFG_FILE $TarFolder$BBHM_CFG_FILE
        	cp /nvram/config/$WIRELESS_CFG_FILE $TarFolder$WIRELESS_CFG_FILE
       		sed -i "s/.*passphrase.*/\toption passphrase \'\'/g" $TarFolder$WIRELESS_CFG_FILE
        fi

	echo "*.tgz" > $PATTERN_FILE # .tgz should be excluded while tar
	if [ -f /tmp/backup_onboardlogs ] && [ -f /nvram/.device_onboarded ]; then
	    echo "tar activation logs from backupnvram2logs_on_reboot"
	    copy_onboardlogs "$TarFolder"
	    tar -X $PATTERN_FILE -cvzf $MAC"_Logs_"$dt"_activation_log.tgz" $TarFolder
	    rm -rf /tmp/backup_onboardlogs
    else
        echo "tar logs from backupnvram2logs_on_reboot"
	    tar -X $PATTERN_FILE -cvzf $MAC"_Logs_$dt.tgz" $TarFolder
    fi
	rm $PATTERN_FILE
	
	rm -rf $TarFolder*.txt*
	rm -rf $TarFolder*.log*
	rm -rf $TarFolder*core*
	rm -rf $TarFolder*.bin*

	if [ "$BOX_TYPE" == "HUB4" ] || [ "$BOX_TYPE" == "SR300" ] || [ "$BOX_TYPE" == "SR213" ] || [ "$BOX_TYPE" == "SE501" ] || [ "$BOX_TYPE" == "WNXL11BWL" ] || [ "$BOX_TYPE" == "SCER11BEL" ] || [ "$BOX_TYPE" == "SCXF11BFL" ]; then
		rm -rf $TarFolder*tar.gz*
	fi

	rm -rf $TarFolder$PcdLogFile
	rm -rf $TarFolder$RAM_OOPS_FILE
	if [ "$BOX_TYPE" = "XB6" ]; then
		rm -rf $TarFolder$SYSCFG_FILE
		rm -rf $TarFolder$BBHM_CFG_FILE
		rm -rf $TarFolder$WIRELESS_CFG_FILE
	fi

	if [ "$BOX_TYPE" = "XB3" ]
	then
		echo_t "RDK_LOGGER: keeping the tar file in tmp for xb3. "
	else
		UploadFile=`ls $TarCreatePath | grep "tgz"`
		if [ "$UploadFile" != "" ]
		then
			logThreshold=`syscfg get log_backup_threshold`
			logBackupEnable=`syscfg get log_backup_enable`
			if [ "$logBackupEnable" = "true" ] && [ "$logThreshold" -gt "0" ]; then
				echo_t "RDK_LOGGER: Moving file  $TarCreatePath/$UploadFile to preserve folder for non-xb3. "
				if [ ! -d $PRESERVE_LOG_PATH ] ; then
					mkdir -p $PRESERVE_LOG_PATH
				fi
				preserveThisLog $UploadFile $TarCreatePath
			else
				echo_t "RDK_LOGGER: Keeping the tar in $TarCreatePath for non-xb3"
			fi
		fi
	fi
	cd $workDir
}

backupAllLogs()
{
	source=$1
	destn=$2
	operation=$3
	MAC=`getMacAddressOnly`

	dt=`date "+%m-%d-%y-%I-%M%p"`
	workDir=`pwd`
	
        # MAINTENANCE_WINDOW is flagged by maintenance window upload script so that 
        # we will not print the sysDecr value again
        if [ ! -f "$MAINTENANCE_WINDOW" ]
        then
          # Put system descriptor string in log file
	  createSysDescr
        else
           rm -rf $MAINTENANCE_WINDOW
        fi

	if [ ! -d "$destn" ]
	then

	   mkdir -p $destn
	else
	   FILE_EXISTS=`ls $destn`
	   if [ "$FILE_EXISTS" != "" ]
       	   then
          	rm -rf $LOG_BACK_UP_PATH*
	   fi
	fi	

	# Syncing ATOM side logs
	if [ "$ATOM_SYNC" = "yes" ]
	then
		echo_t "Check whether ATOM ip accessible before syncing ATOM side logs"
		if [ -f $PING_PATH/ping_peer ]
		then

   		        PING_RES=`ping_peer`
			CHECK_PING_RES=`echo $PING_RES | grep "packet loss" | cut -d"," -f3 | cut -d"%" -f1`

			if [ "$CHECK_PING_RES" != "" ]
			then
				if [ "$CHECK_PING_RES" != "100" ]
				then
					echo_t "Ping to ATOM ip success, syncing ATOM side logs"					
					sync_atom_log_files $LOG_PATH
					# dmcli eRT setv Device.Logging.FlushAllLogs bool true
					echo_t "Call dca for log processing and then flush ATOM logs"
					flush_atom_logs &
					 
				else
					echo_t "Ping to ATOM ip falied, not syncing ATOM side logs"
				fi
			else
				echo_t "Ping to ATOM ip falied, not syncing ATOM side logs"
			fi
		fi

	fi	
	cd $destn
	mkdir $dt

	# Check all files in source folder rather just the main log files
	SOURCE_FILES=`ls $source`

	for fname in $SOURCE_FILES
	do
		$operation $source$fname $dt; >$source$fname;
	done
	cp /version.txt $dt
        if [ "$MODEL_NUM" = "CGM4981COM" ] || [ "${MODEL_NUM}" = "CGM601TCOM" ] || [ "${MODEL_NUM}" = "SG417DBCT" ] || [ "${MODEL_NUM}" = "CWA438TCOM" ] || [ "$MODEL_NUM" == "SR213" ]; then		
              cp $SE05x_tmp_logs $dt$SE05x_rdk_logs
        fi
	if [ "$BOX_TYPE" = "XB6" ]; then
		cp $SYSCFG_DB_FILE $dt$SYSCFG_FILE
        cp /nvram/$BBHM_CFG_FILE $dt$BBHM_CFG_FILE
        cp /nvram/config/$WIRELESS_CFG_FILE $dt$WIRELESS_CFG_FILE
        sed -i "s/.*passphrase.*/\toption passphrase \'\'/g" $dt$WIRELESS_CFG_FILE
    fi

	echo "*.tgz" > $PATTERN_FILE # .tgz should be excluded while tar
	if [ -f /tmp/backup_onboardlogs ] && [ -f /nvram/.device_onboarded ]; then
	    echo "tar activation logs from backupAllLogs"
	    copy_onboardlogs "$dt"
	    tar -X $PATTERN_FILE -cvzf $MAC"_Logs_"$dt"activation_log.tgz" $dt
	    rm -rf /tmp/backup_onboardlogs
	else
	    echo "tar logs from backupAllLogs"
	    tar -X $PATTERN_FILE -cvzf $MAC"_Logs_$dt.tgz" $dt
    fi
	rm $PATTERN_FILE
 	rm -rf $dt
	cd $workDir
}

rotateLogs()
{

	fileName=$1
	if [ ! -d $LOGTEMPPATH ]
	then
		mkdir -p $LOGTEMPPATH
	fi
	
	if [ ! -e $LOGTEMPPATH$fileName ]
	then
		touch $LOGTEMPPATH$fileName
	fi
	#ls $LOGTEMPPATH

	cat $LOG_PATH$fileName >> $LOGTEMPPATH$fileName
	#echo "" > $LOG_PATH$fileName
    >$LOG_PATH$fileName
}

allFileExists()
{
   source=$1
   local fileMissing=0
   for fname in $LOG_FILES_NAMES
   do
   	if [ ! -f $source$fname ]
   	then
   	    fileMissing=1
   	fi
   done

   if [ $fileMissing -eq 1 ]
   then
       echo "no"
   else
       echo "yes"
   fi
   
}

syncLogs()
{
    if [ ! -d $NVRAM_LOG_PATH ]; then
	#echo "making directory"
	mkdir -p $NVRAM_LOG_PATH  # used by no nvram2 device
    fi
    #result=`allFileExists $LOG_PATH`
    #if [ "$result" = "no" ]
    #then
    #return

    file_list=`ls $LOG_PATH`

    for file in $file_list
    do
	cp $LOG_PATH$file $NVRAM_LOG_PATH # Copying all log files directly
    done
    for fname in $LOG_FILES_NAMES
    do
	if [ -f $LOG_PATH$fname ]
   	then
   		cat $LOG_PATH$fname >> $LOG_BACK_UP_REBOOT$fname
   	fi

    #    if [ -f $LOG_BACK_UP_REBOOT$fname ]
	#then
	#	$LOG_BACK_UP_REBOOT$fname > $LOG_PATH$fname
	#fi
   done
    #fi
	
	#for fname in $LOG_FILES_NAMES
	#do
	#    	cat $LOG_PATH$fname >> $LOG_BACK_UP_REBOOT$fname
	#done
	
	#moveFiles $LOG_BACK_UP_REBOOT $LOG_PATH
	#rm -rf $LOG_BACK_UP_REBOOT

    if [ -f /tmp/backup_onboardlogs ]; then
        backup_onboarding_logs
    fi
}


logCleanup()
{
  rm $LOG_PATH/*
  rm $LOG_BACK_UP_PATH/*
  echo_t "Done Log Backup"
}

processDCMResponse()
{

    if [ -f "$DCMRESPONSE" ] 
    then
	
		 cp $DCMRESPONSE $DCMRESPONSE_TMP

        	# Start pre-processing the original file
		sed -i 's/,"urn:/\n"urn:/g' $DCMRESPONSE_TMP # Updating the file by replacing all ',"urn:' with '\n"urn:'
		sed -i 's/^{//g' $DCMRESPONSE_TMP # Delete first character from file '{'
		sed -i 's/}$//g' $DCMRESPONSE_TMP # Delete first character from file '}'
		echo "" >> $DCMRESPONSE_TMP         # Adding a new line to the file
		# Start pre-processing the original file

		UPLOAD_LOGS=""
		while read line
		do
		    # Special processing for telemetry
		   #  echo "line = $line"
		    Check_For_Log_Upload_Setting=`echo "$line" | grep  "LogUploadSettings:upload"`
		    if [ "$Check_For_Log_Upload_Setting" != "" ];then
				UPLOAD_LOGS=`echo "$line" | awk -F ":" '{print $NF}'`
                                if [ "$UPLOAD_LOGS" = "" ]
                                then
                                     UPLOAD_LOGS="true"
                                fi
				sysevent set UPLOAD_LOGS_VAL_DCM $UPLOAD_LOGS
				touch $DCM_SETTINGS_PARSED
				echo "$UPLOAD_LOGS"
				break		
		    fi
		done < $DCMRESPONSE_TMP	

		if [ "$UPLOAD_LOGS" = "" ]
		then
                    UPLOAD_LOGS="true"
                    sysevent set UPLOAD_LOGS_VAL_DCM $UPLOAD_LOGS
                    touch $DCM_SETTINGS_PARSED
                    echo "$UPLOAD_LOGS"
		fi

    else
	UPLOAD_LOGS="false"
	sysevent set UPLOAD_LOGS_VAL_DCM $UPLOAD_LOGS
	touch $DCM_SETTINGS_PARSED
	echo "$UPLOAD_LOGS"
    fi
}

getMaxSize()
{
    size_list=$1
    total_size=0
    for size in $size_list
    do
        total_size=$((total_size+size))
    done
    echo $total_size
}

compress_onboard_logs()
{
    curDir=`pwd`
    cd $ONBOARDLOGS_NVRAM_BACKUP_PATH
    file_list=`ls OnBoarding*`
    echo_t "tar onboard logs to reduce size"
    echo "*.tgz" > $PATTERN_FILE
    dt=`date "+%m-%d-%y-%I-%M%p"`
    MAC=`getMacAddressOnly`
    mkdir $dt
    for file in $file_list
    do
        cp $file $dt; >$file;
    done
    env GZIP=-9 tar -X $PATTERN_FILE -cvzf $MAC"_Logs_"$dt"_OnBoard.tgz" $dt
    rm -rf $dt
    cd $curDir
}

upload_onboard_files()
{
    curDir=`pwd`
    cd $ONBOARDLOGS_NVRAM_BACKUP_PATH
    file_list=`ls`
    #uploading onboard logs to log server
    echo_t "Uploading onboard files"
    file_list=`ls *.tgz`
    for file in $file_list
    do
        $RDK_LOGGER_PATH/onboardLogUpload.sh "upload" $file
    done
    cd $curDir
}

copy_onboard_files()
{
    curDir=`pwd`
    cd $ONBOARDLOGS_NVRAM_BACKUP_PATH
    file_list=`ls *.tgz`
    echo_t "Copying onboard files to $ONBOARDLOGS_TMP_BACKUP_PATH"
    for file in $file_list
    do
        mv $file $ONBOARDLOGS_TMP_BACKUP_PATH
    done
    cd $curDir
}

backup_onboarding_logs()
{
    if [ ! -d $ONBOARDLOGS_NVRAM_BACKUP_PATH ]; then
        mkdir -p $ONBOARDLOGS_NVRAM_BACKUP_PATH
    fi
    curDir=`pwd`

    #copy/append onboard logs to $ONBOARDLOGS_NVRAM_BACKUP_PATH
    cd $LOG_PATH
    file_list=`ls OnBoarding*`
    echo_t "backup onboardlogs to nvram"
    for file in $file_list
    do
        if [ -f $ONBOARDLOGS_NVRAM_BACKUP_PATH$file ]; then
            cat $LOG_PATH$file >> $ONBOARDLOGS_NVRAM_BACKUP_PATH$file
            >$LOG_PATH$file
            if [ "$BOX_TYPE" == "XB3" ];then
                rpcclient  $ATOM_ARPING_IP ">$LOG_PATH$file"
            fi
        else
            cp $LOG_PATH$file $ONBOARDLOGS_NVRAM_BACKUP_PATH
            >$LOG_PATH$file
            if [ "$BOX_TYPE" == "XB3" ];then
                rpcclient  $ATOM_ARPING_IP ">$LOG_PATH$file"
            fi
        fi
    done
    cd $curDir

    #Checking onboarding logs size and compressing to reduce size
    size_list=`du -sk $ONBOARDLOGS_NVRAM_BACKUP_PATH/OnBoarding*|awk '{print $1}'`
    max_size=`getMaxSize "$size_list"`
    echo_t "OnBoard files size is $max_size KB"
    if [ $max_size -ge $MAX_NVRAM_ONBOARDING_FILES_SIZE ];then
        compress_onboard_logs
    fi

    #Checking onboarding logs size along with zipped files size and uploading to server
    max_size=`du -sk $ONBOARDLOGS_NVRAM_BACKUP_PATH|awk '{print $1}'`
    echo_t "$ONBOARDLOGS_NVRAM_BACKUP_PATH size is $max_size KB"
    if [ $max_size -gt $MAX_NVRAM_ONBOARDING_FILES_SIZE ];then
        upload_onboard_files
        if [ ! -d $ONBOARDLOGS_TMP_BACKUP_PATH ]; then
            mkdir -p $ONBOARDLOGS_TMP_BACKUP_PATH
            #copying onboard files
            copy_onboard_files
        else
            #Checking space availability in /tmp
            max_size=`du -sk $ONBOARDLOGS_TMP_BACKUP_PATH|awk '{print $1}'`
            echo_t "$ONBOARDLOGS_TMP_BACKUP_PATH size is $max_size KB"
            if [ $max_size -gt $MAX_TMP_ONBOARDING_FILES_SIZE ];then
                #removing onboard files
                echo_t "Retaining old onboard files and removing new onboard files from $ONBOARDLOGS_NVRAM_BACKUP_PATH"
                rm -rf $ONBOARDLOGS_NVRAM_BACKUP_PATH/*.tgz
            else
                #copying onboard files
                copy_onboard_files
            fi
        fi
    fi

    echo_t "done onboardlogs backup"
}

copy_onboardlogs()
{
    dest=$1
    echo_t "copy onboardlogs to $1"
    curDir=`pwd`
    cd $ONBOARDLOGS_NVRAM_BACKUP_PATH
    file_list=`ls OnBoarding*`

    for file in $file_list
    do
        cp $ONBOARDLOGS_NVRAM_BACKUP_PATH$file $dest
    done
    cd $curDir
    echo_t "done onboardlogs copy to $1"
}
