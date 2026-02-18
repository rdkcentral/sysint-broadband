#!/bin/sh

input_dir="$1"
output_dir="$2"

# Check if input and output directories are provided
if [ -z "$input_dir" ] || [ -z "$output_dir" ]; then
    echo "Usage: $0 <input_directory> <output_directory>"
    exit 1
fi

# Process each file in the input directory
for input_file in "$input_dir"/*; do
    filename=$(basename "$input_file")
    output_file="$output_dir/$filename"

    awk '
    BEGIN {
        prev_message = ""
        repeat_count = 0
        first_line = ""
        timestamp_list = ""
    }

    function flush_repeated() {
        if (repeat_count > 0) {
            if (repeat_count > 1) {
                print first_line " (Suppressed count: " (repeat_count - 1) ", Occurrences: " timestamp_list ".)"
            } else {
                print first_line
            }
            repeat_count = 0
            prev_message = ""
            first_line = ""
            timestamp_list = ""
        }
    }

    {
        if (length($0) == 0) next

        has_timestamp = 0
        timestamp = ""
        message = ""

        # Extract timestamp and message using various formats
        if (match($0, /^[0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^[0-9-]+-[0-9:.]+ /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^\[[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\] /)) {
            timestamp = substr($0, 2, RLENGTH - 2)
            message = substr($0, RLENGTH + 2)
            has_timestamp = 1
        } else if (match($0, /^[A-Za-z]+, [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}:/)) {
            timestamp = substr($0, 1, RLENGTH - 1)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^[0-9]{8} [0-9]{6}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z]{3} [0-9]{4} /) || match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^\[OneWifi\] [0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}<[IE]> /)) {
            timestamp = substr($0, 11, 17)
            message = substr($0, 30)
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
            timestamp = substr($0, 1, 19)
            message = substr($0, 21)
            has_timestamp = 1
        } else if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{2}\/[0-9]{2}\/[0-9]{4})\] /)) {
            timestamp = substr($0, 2, RLENGTH - 3)
            message = substr($0, RLENGTH + 2)
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*:/)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            has_timestamp = 1
        }

        # Handle lines with timestamps
        if (has_timestamp) {
            # Check if this message is the same as previous (consecutive repetition)
            if (message == prev_message) {
                # Consecutive repetition detected
                repeat_count++
                if (timestamp_list != "") {
                    timestamp_list = timestamp_list ", " timestamp
                } else {
                    timestamp_list = timestamp
                }
            } else {
                # Different message - flush previous if any
                flush_repeated()
                
                # Start tracking this new message
                prev_message = message
                repeat_count = 1
                first_line = $0
                timestamp_list = timestamp
            }
        } else {
            # Line without timestamp - flush any pending and print as-is
            flush_repeated()
            print $0
        }
    }

    END {
        # Flush any remaining repeated messages
        flush_repeated()
    }' "$input_file" > "$output_file"

done
