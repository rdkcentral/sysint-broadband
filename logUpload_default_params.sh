#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2022 RDK Management
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

PARTNER_URL_CACHE="/tmp/.rdklogger_partnerid_url_cache"
_need_resolve=true

if [ -f "$PARTNER_URL_CACHE" ]; then
    # Invalidate cache if DCMSettings.conf was updated after cache was written
    if [ -f /tmp/DCMSettings.conf ] && [ /tmp/DCMSettings.conf -nt "$PARTNER_URL_CACHE" ]; then
        _need_resolve=true
    else
        . "$PARTNER_URL_CACHE"
        # Validate that cached values are non-empty
        if [ -n "$partnerId" ] && [ -n "$URL" ]; then
            _need_resolve=false
        fi
    fi
fi

if [ "$_need_resolve" = "true" ]; then
    source /lib/rdk/getpartnerid.sh

    partnerId="$(getPartnerId)"

    Default_URL_logupload="$(dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_Syndication.LogUploadURL | grep string | cut -d":" -f3- | cut -d" " -f2- | tr -d ' ')"

    if [ "$Default_URL_logupload" = "" ];then
       if [ "$partnerId" = "sky-uk" ];then
          Default_URL_logupload="https://ssr.xdp.eu-1.xcal.tv/cgi-bin/sky-S3.cgi"
       else
          Default_URL_logupload="https://ssr.ccp.xcal.tv/cgi-bin/rdkb.cgi"
       fi
    fi

    URL="$Default_URL_logupload"

    if [ -f /tmp/DCMSettings.conf ]; then
          URL=`grep 'LogUploadSettings:UploadRepository:URL' /tmp/DCMSettings.conf | cut -d '=' -f2`
          if [ -z "$URL" ]; then
                echo "urn:settings:LogUploadSettings:UploadRepository' is not found in DCMSettings.conf"
                URL="$Default_URL_logupload"
          else
                echo "upload URL is $URL in DCMSettings.conf"
          fi
    fi

    # Write cache atomically (write to temp then move to avoid partial reads)
    _tmp_cache="${PARTNER_URL_CACHE}.$$"
    echo "partnerId=\"$partnerId\"" > "$_tmp_cache"
    echo "URL=\"$URL\"" >> "$_tmp_cache"
    mv "$_tmp_cache" "$PARTNER_URL_CACHE"
fi