#!/usr/bin/env bash
# n8n-services-snapshot.sh - Snapshot collector for the SERVICES node.
#
# Installed on the Resource Server's nginx node as
# /usr/local/bin/n8n-server-snapshot.sh (same path the workflow calls), so the
# shipped Server Monitor workflow needs no change. It gathers:
#   1. local service health (MariaDB, Redis sessions, OpenSearch) over the
#      env's internal network,
#   2. the full PHP-box snapshot, by ssh-ing to the AppServer as nginx and
#      running its root-owned n8n-server-snapshot.sh via sudo.
#
# Runs as root (NOPASSWD sudo from the n8n user). The ssh hop is done as the
# n8n user so its own key (/var/lib/n8n/.ssh/id_ed25519) is used.
#
# Config: /etc/magento-monitor.env  (PHPBOX_HOST, DB_HOST, REDIS_HOST, ES_HOST)

set -u

ENV_FILE=/etc/magento-monitor.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${PHPBOX_HOST:=}"
: "${DB_HOST:=DB_MASTER}"
: "${REDIS_HOST:=RD_MASTER}"
: "${ES_HOST:=ES_MASTER}"
N8N_USER=n8n
N8N_KEY=/var/lib/n8n/.ssh/id_ed25519

section() { printf '\n=== %s ===\n' "$1"; }
run() { timeout 10 "$@" 2>&1 || true; }
runsh() { timeout 10 bash -c "$1" 2>&1 || true; }

section "SERVICES NODE"
run hostname -f
run date -Is
run uptime
runsh "df -hT --total | grep -v -E 'tmpfs|devtmpfs|overlay'"
run free -h

section "MARIADB ($DB_HOST)"
runsh "mysqladmin -h $DB_HOST ping 2>&1"
runsh "mysql -h $DB_HOST -N -e \"SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Uptime','Slow_queries','Aborted_connects')\" 2>&1"

section "REDIS SESSIONS ($REDIS_HOST)"
runsh "redis-cli -h $REDIS_HOST ping 2>&1"
runsh "redis-cli -h $REDIS_HOST info memory 2>/dev/null | grep -E 'used_memory_human|maxmemory_human'"
runsh "redis-cli -h $REDIS_HOST info clients 2>/dev/null | grep connected_clients"

section "OPENSEARCH ($ES_HOST)"
runsh "curl -s --max-time 10 http://$ES_HOST:9200/_cluster/health"
runsh "curl -s --max-time 10 'http://$ES_HOST:9200/_cat/indices?h=index,health,docs.count,store.size' | head -20"

section "N8N SERVICE"
run systemctl is-active n8n
runsh "tail -20 /var/log/n8n.log 2>/dev/null | grep -iE 'error|warn' | tail -10"

if [ -z "$PHPBOX_HOST" ]; then
  section "PHP BOX"
  echo "PHPBOX_HOST not set in $ENV_FILE - remote snapshot skipped"
  exit 0
fi

section "PHP BOX ($PHPBOX_HOST) - remote snapshot"
timeout 60 runuser -u "$N8N_USER" -- ssh -i "$N8N_KEY" \
    -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "nginx@$PHPBOX_HOST" sudo /usr/local/bin/n8n-server-snapshot.sh 2>&1 \
  || echo "REMOTE SNAPSHOT FAILED (ssh exit $?) - is the monitor key authorised on the PHP box?"

exit 0
