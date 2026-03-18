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
#
# Log Upload Statistics Utility
#
# Usage: log_upload_stats.sh [command]
#
# Commands:
#   show    - Display current log upload statistics (default)
#   reset   - Reset all statistics (persistent and session)
#   reset-session - Reset only session statistics
#   json    - Output statistics in JSON format
#   help    - Show this help message
#
##########################################################################

RDK_LOGGER_PATH="/rdklogger"

# Source the logfiles.sh to get the tracking functions
if [ -f "$RDK_LOGGER_PATH/logfiles.sh" ]; then
    . "$RDK_LOGGER_PATH/logfiles.sh"
elif [ -f "$(dirname "$0")/logfiles.sh" ]; then
    . "$(dirname "$0")/logfiles.sh"
else
    echo "Error: Cannot find logfiles.sh"
    exit 1
fi

# JSON output function
log_upload_stats_json()
{
    _init_upload_stats
    
    local total_uploads total_failed total_orig total_uploaded
    local session_uploads session_failed session_orig session_uploaded
    local last_upload savings_pct session_savings_pct
    
    # Persistent (all-time) stats
    total_uploads=$(_get_stat "total_uploads" "$LOG_UPLOAD_STATS_FILE")
    total_failed=$(_get_stat "total_failed" "$LOG_UPLOAD_STATS_FILE")
    total_orig=$(_get_stat "total_bytes_original" "$LOG_UPLOAD_STATS_FILE")
    total_uploaded=$(_get_stat "total_bytes_uploaded" "$LOG_UPLOAD_STATS_FILE")
    last_upload=$(_get_stat "last_upload_time" "$LOG_UPLOAD_STATS_FILE")
    
    # Session stats
    session_uploads=$(_get_stat "session_uploads" "$LOG_UPLOAD_STATS_TMP")
    session_failed=$(_get_stat "session_failed" "$LOG_UPLOAD_STATS_TMP")
    session_orig=$(_get_stat "session_bytes_original" "$LOG_UPLOAD_STATS_TMP")
    session_uploaded=$(_get_stat "session_bytes_uploaded" "$LOG_UPLOAD_STATS_TMP")
    
    # Calculate savings percentages
    if [ "${total_orig:-0}" -gt 0 ]; then
        savings_pct=$(( (total_orig - total_uploaded) * 100 / total_orig ))
    else
        savings_pct=0
    fi
    
    if [ "${session_orig:-0}" -gt 0 ]; then
        session_savings_pct=$(( (session_orig - session_uploaded) * 100 / session_orig ))
    else
        session_savings_pct=0
    fi
    
    cat << EOF
{
  "persistent": {
    "total_uploads": ${total_uploads:-0},
    "total_failed": ${total_failed:-0},
    "total_bytes_original_kb": ${total_orig:-0},
    "total_bytes_uploaded_kb": ${total_uploaded:-0},
    "savings_percent": ${savings_pct},
    "last_upload_timestamp": ${last_upload:-0}
  },
  "session": {
    "uploads": ${session_uploads:-0},
    "failed": ${session_failed:-0},
    "bytes_original_kb": ${session_orig:-0},
    "bytes_uploaded_kb": ${session_uploaded:-0},
    "savings_percent": ${session_savings_pct}
  }
}
EOF
}

show_help()
{
    cat << EOF
Log Upload Statistics Utility

Usage: $0 [command]

Commands:
  show          Display current log upload statistics (default)
  reset         Reset all statistics (persistent and session)
  reset-session Reset only session statistics
  json          Output statistics in JSON format
  help          Show this help message

Description:
  This utility tracks and displays log upload statistics to measure
  the effectiveness of log suppression in reducing upload data volume.

Statistics tracked:
  - Total number of successful uploads
  - Total number of failed upload attempts
  - Original log data size (before suppression/compression)
  - Uploaded data size (after suppression/compression)
  - Data savings percentage
  - Last successful upload timestamp

Examples:
  $0 show           # Display statistics
  $0 json           # Get stats in JSON for automation
  $0 reset          # Clear all statistics
  $0 reset-session  # Clear only current session stats

EOF
}

# Main command handling
case "${1:-show}" in
    show)
        log_upload_print_stats
        ;;
    reset)
        log_upload_reset_stats "all"
        echo "All statistics have been reset."
        ;;
    reset-session)
        log_upload_reset_stats "session"
        echo "Session statistics have been reset."
        ;;
    json)
        log_upload_stats_json
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use '$0 help' for usage information."
        exit 1
        ;;
esac
