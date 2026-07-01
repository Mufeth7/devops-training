#!/bin/bash

INPUT_FILE=$1
OUTPUT_LOG="health_report.log"
ALERT_FILE="alert.log"

# Email option
EMAIL=""

shift

while getopts "e:" opt; do
  case $opt in
    e) EMAIL=$OPTARG ;;
  esac
done

echo "HOST | PORT | DNS_IP | TCP_STATUS | HTTP_CODE | LATENCY_MS" > "$OUTPUT_LOG"

resolve_dns() {
    host=$1
    getent hosts "$host" | awk '{print $1}' | head -1
}

tcp_check() {
    host=$1
    port=$2
    timeout 3 bash -c "</dev/tcp/$host/$port" &>/dev/null
    if [ $? -eq 0 ]; then
        echo "OK"
    else
        echo "FAIL"
    fi
}

http_check() {
    url=$1
    result=$(curl -o /dev/null -s -w "%{http_code} %{time_total}" "$url")
    http_code=$(echo $result | awk '{print $1}')
    latency=$(echo $result | awk '{printf "%.0f", $2*1000}')
    echo "$http_code $latency"
}

while IFS=: read -r host port
do
    [ -z "$host" ] && continue

    DNS_IP=$(resolve_dns "$host")
    [ -z "$DNS_IP" ] && DNS_IP="N/A"

    TCP_STATUS=$(tcp_check "$host" "$port")

    HTTP_CODE="-"
    LATENCY="0"

    if [[ "$port" == "80" || "$port" == "443" ]]; then
        protocol="http"
        [ "$port" == "443" ] && protocol="https"

        read HTTP_CODE LATENCY <<< $(http_check "$protocol://$host")
    fi

    echo "$host | $port | $DNS_IP | $TCP_STATUS | $HTTP_CODE | ${LATENCY}ms" >> "$OUTPUT_LOG"

    if [ "$TCP_STATUS" == "FAIL" ]; then
        ERROR_MSG="$(date) ERROR - $host:$port unreachable"

        echo "$ERROR_MSG" >> "$OUTPUT_LOG"

        # ✅ Email simulation
        if [ -n "$EMAIL" ]; then
            echo "ALERT to $EMAIL: $ERROR_MSG" >> "$ALERT_FILE"
        fi
    fi

done < "$INPUT_FILE"

echo "Feature branch: Health check + email alerts completed"
