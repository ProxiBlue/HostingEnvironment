#!/bin/bash
# OpenSearch health check - run via cron on the ES node
# Restarts OpenSearch if it's unresponsive or cluster is red

LOGFILE="/var/log/opensearch/healthcheck.log"
MAX_FAILURES=3
FAILURE_FILE="/tmp/opensearch_failures"

response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost:9200/_cluster/health 2>/dev/null)

if [ "$response" = "200" ]; then
    # Check if cluster status is red
    status=$(curl -s --max-time 10 http://localhost:9200/_cluster/health 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [ "$status" = "red" ]; then
        echo "$(date) - Cluster status RED" >> "$LOGFILE"
        count=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$FAILURE_FILE"
        if [ "$count" -ge "$MAX_FAILURES" ]; then
            echo "$(date) - $MAX_FAILURES consecutive red status, restarting OpenSearch" >> "$LOGFILE"
            supervisorctl restart opensearch >> "$LOGFILE" 2>&1
            echo 0 > "$FAILURE_FILE"
        fi
    else
        echo 0 > "$FAILURE_FILE"
    fi
else
    echo "$(date) - OpenSearch unresponsive (HTTP $response)" >> "$LOGFILE"
    count=$(cat "$FAILURE_FILE" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$FAILURE_FILE"
    if [ "$count" -ge "$MAX_FAILURES" ]; then
        echo "$(date) - $MAX_FAILURES consecutive failures, restarting OpenSearch" >> "$LOGFILE"
        supervisorctl restart opensearch >> "$LOGFILE" 2>&1
        echo 0 > "$FAILURE_FILE"
    fi
fi
