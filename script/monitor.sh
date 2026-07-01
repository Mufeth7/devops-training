#!/bin/bash
LOG_LEVEL="ERROR"
RETENTION_DAYS=7
usage() {
    echo "Usage: $0 -d <directory> [-l <log_level>] [-r <retention_days>]"
    exit 1
}
while getopts "d:l:r:" opt
do
    case $opt in
        d) LOG_DIR=$OPTARG ;;
        l) LOG_LEVEL=$OPTARG ;;
        r) RETENTION_DAYS=$OPTARG ;;
        *) usage ;;
    esac
done
if [ -z "$LOG_DIR" ]; then
    echo "Error: Please provide a directory using -d"
    usage
fi
if [ ! -d "$LOG_DIR" ]; then
    echo "Error: Directory '$LOG_DIR' does not exist"
    exit 1
fi
REPORT_DIR="/opt/app/logs"
mkdir -p "$REPORT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$REPORT_DIR/report_${TIMESTAMP}.txt"
echo "Log Summary Report" > "$REPORT_FILE"
echo "Generated: $(date)" >> "$REPORT_FILE"
echo "Directory: $LOG_DIR" >> "$REPORT_FILE"
echo "Log Level: $LOG_LEVEL" >> "$REPORT_FILE"
echo "----------------------------------" >> "$REPORT_FILE"
FOUND_LOGS=0
CRITICAL_FOUND=0
for file in "$LOG_DIR"/*.log
do
    if [ ! -e "$file" ]; then
        continue
    fi
    FOUND_LOGS=1
    if [ ! -r "$file" ]; then
        echo "$(basename "$file") : UNREADABLE" >> "$REPORT_FILE"
        continue
    fi
    COUNT=$(grep -c "$LOG_LEVEL" "$file" 2>/dev/null)
    echo "$(basename "$file") : $COUNT" >> "$REPORT_FILE"
    if [ "$LOG_LEVEL" = "ERROR" ] && [ "$COUNT" -gt 100 ]; then
        echo "[CRITICAL] $(basename "$file") contains $COUNT ERROR entries" >&2
        CRITICAL_FOUND=1
    fi
done
if [ $FOUND_LOGS -eq 0 ]; then
    echo "No .log files found in directory" >> "$REPORT_FILE"
fi
find "$REPORT_DIR" -name "report_*.txt" -type f -mtime +$RETENTION_DAYS -delete 2>/dev/null
echo "Report saved to: $REPORT_FILE"
if [ $CRITICAL_FOUND -eq 1 ]; then
    exit 1
fi
exit 0
 