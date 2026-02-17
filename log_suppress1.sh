#!/bin/sh

if [ $# -ne 2 ]; then
    echo "Usage: $0 input_directory output_directory"
    exit 1
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Input directory '$INPUT_DIR' not found"
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Counter for processed files
processed=0
total=0

# Count total files
for file in "$INPUT_DIR"/*; do
    if [ -f "$file" ]; then
        total=$((total + 1))
    fi
done

echo "Processing $total file(s) from $INPUT_DIR..."
echo ""

# Process each file in the input directory
for INPUT_FILE in "$INPUT_DIR"/*; do
    # Skip if not a file
    if [ ! -f "$INPUT_FILE" ]; then
        continue
    fi
    
    # Get just the filename (without path)
    FILENAME=$(basename "$INPUT_FILE")
    OUTPUT_FILE="$OUTPUT_DIR/$FILENAME"
    
    echo "Processing: $FILENAME"
    
    awk '
BEGIN {
    idx = 0
}

{
    # Skip empty lines
    if (length($0) == 0 || $0 ~ /^[[:space:]]*$/) {
        next
    }
    
    idx++
    lines[idx] = $0
    has_timestamp = 0
    timestamp = ""
    message = ""
    
    # Try to extract timestamp - supports multiple formats
    # Format: YYMMDD-HH:MM:SS.microseconds (6 digits for date)
    if (match($0, /^[0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DD-HH:MM:SS.microseconds or similar dash-separated
    else if (match($0, /^[0-9-]+-[0-9:.]+ /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY MMM DD HH:MM:SS (e.g., 2024 Jan 15 10:30:45)
    else if (match($0, /^[0-9]{4} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: [Day Mon DD HH:MM:SS YYYY] (e.g., [Mon Jan 15 10:30:45 2024])
    else if (match($0, /^\[[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}\] /)) {
        timestamp = substr($0, 2, RLENGTH - 2)
        message = substr($0, RLENGTH + 2)
        has_timestamp = 1
    }
    # Format: Day, Mon DD HH:MM:SS YYYY: (e.g., Monday, Jan 15 10:30:45 2024:)
    else if (match($0, /^[A-Za-z]+, [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}:/)) {
        timestamp = substr($0, 1, RLENGTH - 1)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYYMMDD HHMMSS.microseconds (e.g., 20240115 103045.123456)
    else if (match($0, /^[0-9]{8} [0-9]{6}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: Day Mon DD HH:MM:SS TZ YYYY or Day Mon DD HH:MM:SS YYYY
    else if (match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z]{3} [0-9]{4} /) || match($0, /^[A-Za-z]{3} [A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: [OneWifi] YYMMDD-HH:MM:SS.microseconds<I/E> 
    else if (match($0, /^\[OneWifi\] [0-9]{6}-[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}<[IE]> /)) {
        timestamp = substr($0, 11, 17)
        message = substr($0, 30)
        has_timestamp = 1
    }
    # Format: YYYY.MM.DD HH:MM:SS (e.g., 2024.01.15 10:30:45)
    else if (match($0, /^[0-9]{4}\.[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} /)) {
        timestamp = substr($0, 1, 19)
        message = substr($0, 21)
        has_timestamp = 1
    }
    # Format: [HH:MM:SS DD/MM/YYYY] (time and date in brackets)
    else if (match($0, /^\[([0-9]{2}:[0-9]{2}:[0-9]{2}) ([0-9]{2}\/[0-9]{2}\/[0-9]{4})\] /)) {
        timestamp = substr($0, 2, RLENGTH - 3)
        message = substr($0, RLENGTH + 2)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DD HH:MM:SS.microseconds (standard datetime)
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6} /)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # Format: YYYY-MM-DDTHH:MM:SS.microsecondsZ: (ISO format)
    else if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z[[:space:]]*:/)) {
        timestamp = substr($0, 1, RLENGTH)
        message = substr($0, RLENGTH + 1)
        has_timestamp = 1
    }
    # No timestamp found - treat entire line as message
    else {
        has_timestamp = 0
        timestamp = ""
        message = $0
    }
    
    timestamps[idx] = timestamp
    content[idx] = message
    gsub(/^[ \t]+/, "", content[idx])
}

END {
    i = 1
    while (i <= idx) {
        found = 0
        
        # If line has no timestamp, print as-is and skip pattern detection
        if (timestamps[i] == "") {
            print lines[i]
            i++
            continue
        }
        
        # First check for single line repetition
        if (i < idx && content[i] == content[i+1]) {
            rep_count = 1
            j = i + 1
            while (j <= idx && content[i] == content[j] && timestamps[j] != "") {
                rep_count++
                j++
            }
            
            if (rep_count > 1) {
                # Single line repetition - show inline suppression
                ts_list = ""
                for (r = 1; r < rep_count; r++) {
                    if (ts_list != "") ts_list = ts_list ","
                    ts_list = ts_list "<" timestamps[i + r] ">"
                }
                print lines[i] " [suppressed count: " (rep_count - 1) ", timestamps: " ts_list "]"
                i += rep_count
                found = 1
            }
        }
        
        # If not single line repetition, try multi-line patterns (3 lines, then 2 lines)
        if (!found) {
            for (plen = 3; plen >= 2 && !found; plen--) {
                if (i + plen > idx) continue
                
                # Check if pattern repeats
                rep_count = 1
                can_continue = 1
                
                while (can_continue && i + plen * (rep_count + 1) <= idx) {
                    matches = 1
                    for (k = 0; k < plen; k++) {
                        if (content[i + k] != content[i + plen * rep_count + k] || timestamps[i + plen * rep_count + k] == "") {
                            matches = 0
                            break
                        }
                    }
                    
                    if (matches) {
                        rep_count++
                    } else {
                        can_continue = 0
                    }
                }
                
                # If pattern repeated at least once
                if (rep_count > 1) {
                    # Multi-line pattern - show pattern then suppression message
                    for (k = 0; k < plen; k++) {
                        print lines[i + k]
                    }
                    
                    # Build timestamp range for suppressed occurrences
                    ts_start = timestamps[i + plen]
                    ts_end = timestamps[i + plen * (rep_count - 1) + plen - 1]
                    
                    if (rep_count == 2) {
                        print "[Above " plen " lines occurred immediately, pattern suppressed, count:" (rep_count - 1) ",timestamps: [" ts_start "] to[" ts_end "]]"
                    } else {
                        print "[Above " plen " lines occurred, pattern suppressed, count:" (rep_count - 1) ",timestamps: [" ts_start "] to[" ts_end "]]"
                    }
                    
                    i += plen * rep_count
                    found = 1
                }
            }
        }
        
        # No pattern found, print line as-is
        if (!found) {
            print lines[i]
            i++
        }
    }
}
' "$INPUT_FILE" > "$OUTPUT_FILE"
    
    processed=$((processed + 1))
    echo "  ✓ Output: $OUTPUT_FILE"
done

echo ""
echo "================================================"
echo "Log suppression completed!"
echo "Processed: $processed/$total files"
echo "Input directory:  $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"
echo "================================================"
