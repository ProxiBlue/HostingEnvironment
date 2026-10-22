#!/bin/bash
# Magento cron health check - runs on the SERVICES node (nginx/n8n node of
# the Resource Server env), every 5 min via root cron.
#   - alerts if no successful Magento cron in the last 15 minutes
#   - restarts cron:run on the PHP box over ssh (as the n8n monitor user)
#   - prunes old cron_schedule rows, marks stuck jobs
#
# Config: /etc/magento-monitor.env  (DB_HOST DB_NAME DB_USER DB_PASS
#                                    PHPBOX_HOST ALERT_EMAIL)

ENV_FILE=/etc/magento-monitor.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${DB_HOST:=DB_MASTER}"
: "${DB_NAME:=magento}"
: "${DB_USER:?DB_USER missing in $ENV_FILE}"
: "${DB_PASS:?DB_PASS missing in $ENV_FILE}"
: "${PHPBOX_HOST:=}"
: "${ALERT_EMAIL:=root}"

LOGFILE="/var/log/magento_cron_healthcheck.log"
THRESHOLD_MINUTES=15
N8N_KEY=/var/lib/n8n/.ssh/id_ed25519

q() { mysql -h "$DB_HOST" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "$1" 2>/dev/null; }

recent_success=$(q "SELECT COUNT(*) FROM cron_schedule WHERE status = 'success' AND executed_at > DATE_SUB(NOW(), INTERVAL $THRESHOLD_MINUTES MINUTE);")

if [ -z "$recent_success" ] || [ "$recent_success" -eq 0 ]; then
    echo "$(date) - WARNING: No successful Magento cron in last $THRESHOLD_MINUTES minutes" >> "$LOGFILE"

    if [ -n "$PHPBOX_HOST" ]; then
        echo "$(date) - kicking cron:run on $PHPBOX_HOST" >> "$LOGFILE"
        timeout 120 runuser -u n8n -- ssh -i "$N8N_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "nginx@$PHPBOX_HOST" \
            'pgrep -f "cron:run" >/dev/null || (cd /var/www/webroot/ROOT && nohup php bin/magento cron:run >/dev/null 2>&1 &)' \
            >> "$LOGFILE" 2>&1
    fi

    echo "Magento cron has not run successfully in $THRESHOLD_MINUTES minutes (PHP box $PHPBOX_HOST, DB $DB_HOST)" | \
        mail -s "ALERT: Magento cron failure ($PHPBOX_HOST)" "$ALERT_EMAIL" 2>/dev/null || true
fi

# Keep cron_schedule small; mark jobs stuck in 'running' for over an hour.
q "DELETE FROM cron_schedule WHERE scheduled_at < DATE_SUB(NOW(), INTERVAL 7 DAY);"
q "UPDATE cron_schedule SET status = 'error', messages = 'Killed by healthcheck - stuck' WHERE status = 'running' AND executed_at < DATE_SUB(NOW(), INTERVAL 1 HOUR);"
