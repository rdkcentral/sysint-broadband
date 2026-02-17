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
    BEGIN { OFS = " : " }

    {
        if (length($0) == 0) next

        if (match($0, /^[0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[0-9-]+-[0-9:.]+ /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^\[[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\] /)) {
            timestamp = substr($0, 2, RLENGTH - 2)
            message = substr($0, RLENGTH + 2)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[A-Za-z]+, [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}:/)) {
            timestamp = substr($0, 1, RLENGTH - 1)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[0-9]{8} [0-9]{6}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z]{3} [0-9]{4} /) || match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else if (match($0, /^\[OneWifi\] [0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}<[IE]> /)) {
            timestamp = substr($0, 11, 17)
            message = substr($0, 30)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
            timestamp = substr($0, 1, 19)
            message = substr($0, 21)
            key = message
            has_timestamp = 1
        } else if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{2}\/[0-9]{2}\/[0-9]{4})\] /)) {
            timestamp = substr($0, 2, RLENGTH - 3)
            message = substr($0, RLENGTH + 2)
            key = message
            has_timestamp = 1
        } else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
            timestamp = substr($0, 1, RLENGTH)
            message = substr($0, RLENGTH + 1)
            key = message
            has_timestamp = 1
        } else {
            message = $0
            key = NR
            has_timestamp = 0
        }

        if (has_timestamp) {
            if (key in messages) {
                split(messages[key], data, "\t")
                count = data[1] + 1
                first_line = data[2]
                timestamps = data[3] (data[3] != "" ? ", " : "") timestamp
                messages[key] = count "\t" first_line "\t" timestamps
            } else {
                messages[key] = "1\t" $0 "\t" timestamp
                order[++num_messages] = key
            }
        } else {
            if (num_messages > 0) {
                for (i = 1; i <= num_messages; i++) {
                    key = order[i]
                    split(messages[key], data, "\t")
                    count = data[1]
                    first_line = data[2]
                    timestamps = data[3]
                    if (count > 1) {
                        print first_line " (Suppressed count: " count ", Occurrences: " timestamps ".)"
                    } else {
                        print first_line
                    }
                }
                delete messages
                delete order
                num_messages = 0
            }
            print message
        }
    }

    END {
        for (i = 1; i <= num_messages; i++) {
            key = order[i]
            split(messages[key], data, "\t")
            count = data[1]
            first_line = data[2]
            timestamps = data[3]
            if (count > 1) {
                print first_line " (Suppressed count: " count ", Occurrences: " timestamps ".)"
            } else {
                print first_line
            }
        }
    }' "$input_file" > "$output_file"

done
