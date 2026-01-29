#!/bin/sh
##############################################################################
# If not stated otherwise in this file or this component's LICENSE file the
# following copyright and licenses apply:
#
# Copyright 2020 RDK Management
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
##############################################################################

. /etc/include.properties
. /etc/device.properties

#Cert ops STB Red State recovery RDKB-37008

stateRedSprtFile="/lib/rdk/stateRedRecovery.sh"
stateRedFlag="/tmp/stateRedEnabled"
STATE_RED_LOG_FILE="/rdklogs/logs/xconf.txt.0"
tlsErr_logs="/rdklogs/logs/tlsError.log"

stateRedlog ()
{
    echo_t "$*" >> "$STATE_RED_LOG_FILE"
}

tlsLog()
{
    echo "`date +"%y%m%d-%T.%6N"` : $0: $*" >> $tlsErr_logs
}

#isStateRedSupported; check if state red supported
isStateRedSupported()
{
    if [ -f $stateRedSprtFile ]; then
        stateRedSupport=1
    else
        stateRedSupport=0
    fi
    return $stateRedSupport
}

#isInStateRed state red status, if set ret 1
#stateRed is local to function
isInStateRed()
{
    stateRed=0
    isStateRedSupported
    stateSupported=$?
    if [ $stateSupported -eq 0 ]; then
         return $stateRed
    fi

    if [ -f $stateRedFlag ]; then
        stateRed=1
    fi
    return $stateRed
}

#unsetStateRed; exit from state red
unsetStateRed()
{
   if [ -f $stateRedFlag ]; then
       stateRedlog "unsetStateRed: Exiting State Red"
       rm -f $stateRedFlag
       tlsLog "unsetStateRed: State Red Recovery Flag Unset!!!"
       tlsLog "unsetStateRed: Exiting from State Red Firmware download Service!!!"
       if [ -f /lib/rdk/t2Shared_api.sh ]; then
           t2ValNotify "certerr_split" "State Red Recovery Exit"
       fi
   fi
   stateredRecoveryURL=""
 }

# checkAndEnterStateRed <curl return code> - enter state red on SSL related error code
checkAndEnterStateRed()
{
    curlReturnValue=$1

    isInStateRed
    stateRedflagset=$?
    if [ $stateRedflagset -eq 1 ]; then
        stateRedlog "checkAndEnterStateRed: device state red recovery flag already set"
        return
    fi

#Enter state red on ssl or cert errors
#HTTP code 495 - Expired certs not in servers allow list
    case $curlReturnValue in
    35|51|53|54|58|59|60|64|66|77|80|82|83|90|91|495)
        stateRedlog "checkAndEnterStateRed: Curl SSL/TLS error ($curlReturnValue). Set State Red Recovery Flag and Exit!!!"
        rm -f $CODEBIG_BLOCK_FILENAME
        rm -f $DOWNLOAD_INPROGRESS
        touch $stateRedFlag
        tlsLog "checkAndEnterStateRed: State Red Recovery Flag Set!!!"
        tlsLog "checkAndEnterStateRed: Triggering State Red Firmware download Service!!!"
        if [ -f /lib/rdk/t2Shared_api.sh ]; then
            t2ValNotify "certerr_split" "State Red Recovery Start"
        fi
        exit 1
    ;;
    esac
}

#getStateRedXconfUrl: get recovery xconf url from bootstrap config
getStateRedXconfUrl()
{
    stateredRecoveryURL=""
    tmp_URL="$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Control.XconfRecoveryUrl | grep string | cut -d":" -f3- | cut -d" " -f2- | tr -d ' ')"
    if [ "$tmp_URL" != "" ];then
	if [ "$direct_CDN" = "true" ];then
            tmp_URL=$(echo "$tmp_URL" | sed 's/swu/firmware/')
            stateredRecoveryURL="${tmp_URL}"
	else
            stateRedlog "XCONF SCRIPT : Setting stateredRecoveryURL : $tmp_URL"
            stateredRecoveryURL="${tmp_URL}"
        fi
    else
	if [ "$direct_CDN" = "true" ];then
	    stateredRecoveryURL="https://recovery.xconfds.coast.xcal.tv/xconf/firmware/stb"
	else
            stateRedlog "XCONF SCRIPT : Setting default stateredRecoveryURL"
            stateredRecoveryURL="https://recovery.xconfds.coast.xcal.tv/xconf/swu/stb"
        fi
    fi
    echo "$stateredRecoveryURL"
}

#getStateRedCreds: get mtls credentials for state red 
getStateRedCreds()
{
    stateRedCreds=""
    if [ -f /etc/ssl/certs/RedRecovery.p12 ]; then
        if [ ! -f /usr/bin/GetConfigFile ]; then
            stateRedlog "Error: State Red GetConfigFile Not Found"
            exit 127
        fi
        stateRedCreds="--cert-type P12 --cert /etc/ssl/certs/RedRecovery.p12 --config /dev/stdin"
    fi
    echo "$stateRedCreds"
}
