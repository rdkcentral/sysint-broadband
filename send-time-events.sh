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

if [ "x$1" = "xsystimeset" ]; then
	/usr/bin/dbus-send --system --type=signal --dest=org.Systime /org/Systime org.Systime.TimeSet \
    		string:"System time has been set to TOD or LKG or BUILD"
elif [ "x$1" = "xntpsyncset" ]; then
	/usr/bin/dbus-send --system --type=signal --dest=org.NtpSync /org/NtpSync org.NtpSync.TimeSet \
    		string:"NTP Sync Completed"
else
  echo "Usage: $0 [systimeset|ntpsyncset]"
fi
