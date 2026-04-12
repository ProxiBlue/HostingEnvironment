#!/bin/bash
# Magento cron health check - run via cron on the cp node
# Alerts if Magento cron hasn't run successfully in the last 15 minutes
# Also cleans up old cron_schedule entries to prevent table bloat

MAGE_ROOT="/var/www/webroot/ROOT"
LOGFILE="/var/log/nginx/magento_cron_healthcheck.log"
ALERT_EMAIL="${BACKUP_FAIL_TO:-root}"
THRESHOLD_MINUTES=15

# Check if any cron job ran successfully in the last N minutes
recent_success=$(mysql -u${DB_USER:-jelastic} -p${DB_PASS:-} -h DB_MASTER magento -N -e \
    "SELECT COUNT(*) FROM cron_schedule WHERE status = 'success' AND executed_at > DATE_SUB(NOW(), INTERVAL $THRESHOLD_MINUTES MINUTE);" 2>/dev/null)

if [ -z "$recent_success" ] || [ "$recent_success" -eq 0 ]; then
    echo "$(date) - WARNING: No successful Magento cron in last $THRESHOLD_MINUTES minutes" >> "$LOGFILE"

    # Check if cron process is running
    if ! pgrep -f "cron:run" > /dev/null 2>&1; then
        echo "$(date) - Magento cron process not found, attempting restart" >> "$LOGFILE"
        cd "$MAGE_ROOT" && sudo -u nginx php bin/magento cron:run >> "$LOGFILE" 2>&1 &
    fi

    # Send alert
    echo "Magento cron has not run successfully in $THRESHOLD_MINUTES minutes on $(hostname)" | \
        mail -s "ALERT: Magento cron failure on $(hostname)" "$ALERT_EMAIL" 2>/dev/null || true
fi

# Clean up old cron_schedule entries (older than 7 days) to prevent table bloat
mysql -u${DB_USER:-jelastic} -p${DB_PASS:-} -h DB_MASTER magento -e \
    "DELETE FROM cron_schedule WHERE scheduled_at < DATE_SUB(NOW(), INTERVAL 7 DAY);" 2>/dev/null

# Clean up stuck jobs (pending for more than 1 hour)
mysql -u${DB_USER:-jelastic} -p${DB_PASS:-} -h DB_MASTER magento -e \
    "UPDATE cron_schedule SET status = 'error', messages = 'Killed by healthcheck - stuck' WHERE status = 'running' AND executed_at < DATE_SUB(NOW(), INTERVAL 1 HOUR);" 2>/dev/null
