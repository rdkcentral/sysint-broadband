#!/bin/sh

####################################################################################
# If not stated otherwise in this file or this component's LICENSE file the
# following copyright and licenses apply:
#
# Copyright 2026 RDK Management
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
####################################################################################

# ──────────────────────────────────────────────────────────────────────────────
# chrony_offset_metrics.sh
#
# Timer-triggered, oneshot sampler for chrony's current clock offset and
# frequency. Fired periodically by chrony-offset-metrics.timer via
# chrony-offset-metrics.service (Type=oneshot). Zero resident memory between
# samples: this script runs, parses `chronyc tracking`, publishes to
# Telemetry 2.0, and exits.
#
# Gated on syscfg:chrony_enabled — a safe no-op when ntpd is the active
# NTP client.
# ──────────────────────────────────────────────────────────────────────────────

. /etc/device.properties

if [ -f /lib/rdk/t2Shared_api.sh ]; then
    source /lib/rdk/t2Shared_api.sh
fi

if [ -z "$NTPD_LOG_NAME" ]; then
    NTPD_LOG_NAME=/rdklogs/logs/ntpLog.log
fi

log_msg() {
    echo "$(date) CHRONY_METRICS : $1" >> "$NTPD_LOG_NAME"
}

# Gate: only sample when chrony is the active RFC-selected NTP client.
chrony_enabled=$(syscfg get chrony_enabled 2>/dev/null)
if [ "$chrony_enabled" != "true" ]; then
    log_msg "ntpd is the active NTP client. Stopping data collection for chronyd."
    exit 0
fi

tracking=$(chronyc tracking 2>/dev/null)
if [ -z "$tracking" ]; then
    log_msg "chronyc tracking failed or returned no output, skipping this sample"
    exit 1
fi

# Match by field label, not fixed column position — chronyc's column widths
# shift depending on the values being printed (see chrony-source-selectable-
# detection-fix for the same failure mode on a different chronyc command).
offset=$(printf '%s\n' "$tracking" | awk '/^Last offset/ {print $4}')
frequency=$(printf '%s\n' "$tracking" | awk '/^Frequency/ {print $3}')
delay=$(printf '%s\n' "$tracking" | awk '/^Root delay/ {print $4}')

if [ -z "$offset" ] || [ -z "$frequency" ] || [ -z "$delay" ]; then
    log_msg "unable to parse Metrics from chronyc tracking output, skipping this sample"
    exit 1
fi

t2ValNotify "SYS_INFO_NTPDELTA_split" "$offset"
t2ValNotify "SYS_INFO_NTPDELAY_split" "$delay"
t2ValNotify "SYS_INFO_NTPFREQUENCY_split" "$frequency"

log_msg "Offset=$offset;Frequency=$frequency;Delay=$delay"
