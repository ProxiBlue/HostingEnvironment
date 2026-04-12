#!/bin/bash
# Redis sessions health check - run via cron on the nosqldb node
# Restarts Redis if it's unresponsive

LOGFILE="/var/log/redis_healthcheck.log"
MAX_FAILURES=3
FAILURE_FILE="/tmp/redis_session_failures"

response=$(redis-cli ping 2>/dev/null)

if [ "$response" = "PONG" ]; then
    echo 0 > "$FAILURE_FILE"
else
    echo "$(date) - Redis sessions not responding (got: $response)" >> "$LOGFILE"
    count=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$FAILURE_FILE"
    if [ "$count" -ge "$MAX_FAILURES" ]; then
        echo "$(date) - $MAX_FAILURES consecutive failures, restarting Redis" >> "$LOGFILE"
        systemctl restart redis >> "$LOGFILE" 2>&1
        echo 0 > "$FAILURE_FILE"
    fi
fi
