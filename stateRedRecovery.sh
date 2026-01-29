#!/bin/sh

. /etc/include.properties

echo "STATE RED RECOVERY, Initiating recovery software download" >> /rdklogs/logs/xconf.txt.0

BOX=`grep BOX_TYPE /etc/device.properties | cut -d "=" -f2 | tr 'A-Z' 'a-z'`

if [ "$BOX" = "tccbr" ]; then
    SCRIPT_NAME="cbr_firmwareDwnld.sh"
elif [ "$BOX" = "vntxer5" ]; then
    SCRIPT_NAME="xer5_firmwareDwnld.sh"
else
    FIRMWARE_DOWNLOAD='_firmwareDwnld.sh'
    SCRIPT_NAME="$BOX$FIRMWARE_DOWNLOAD"
fi
sh /etc/$SCRIPT_NAME 6 2>&1
