#!/bin/bash
# MariaDB health check - run via cron on the sqldb node
# Restarts MariaDB if it's unresponsive

LOGFILE="/var/log/mysql/healthcheck.log"
MAX_FAILURES=3
FAILURE_FILE="/tmp/mariadb_failures"

if mysqladmin ping --silent 2>/dev/null; then
    echo 0 > "$FAILURE_FILE"
else
    echo "$(date) - MariaDB not responding to ping" >> "$LOGFILE"
    count=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$FAILURE_FILE"
    if [ "$count" -ge "$MAX_FAILURES" ]; then
        echo "$(date) - $MAX_FAILURES consecutive failures, restarting MariaDB" >> "$LOGFILE"
        systemctl restart mysql >> "$LOGFILE" 2>&1
        echo 0 > "$FAILURE_FILE"
    fi
fi
