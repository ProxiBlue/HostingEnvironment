#!/usr/bin/env bash
# n8n-server-snapshot.sh - Read-only data collector for the n8n monitoring
# workflow. Outputs a single text blob that the workflow ships to Gemini.
#
# Owned by root, mode 0755. n8n daemon user invokes via NOPASSWD sudo
# (/etc/sudoers.d/n8n) so n8n itself stays unprivileged.
#
# Sections are wrapped in === MARKERS === so the LLM (and any debugging eye)
# can split them. Every command is hardened with timeouts and 'true' fallbacks
# so the helper always exits 0 - the workflow should never block on this.

set -u

section() { printf '\n=== %s ===\n' "$1"; }
run() { timeout 10 "$@" 2>&1 || true; }
runsh() { timeout 10 bash -c "$1" 2>&1 || true; }

MAGE_ROOT="${MAGE_ROOT:-/var/www/webroot/ROOT}"

section "HOSTNAME"
run hostname -f

section "DATE"
run date -Is

section "UPTIME"
run uptime

section "DISK USAGE"
runsh "df -hT --total | grep -v -E 'tmpfs|devtmpfs|overlay'"

section "MEMORY"
run free -h

section "TOP MEM PROCESSES"
runsh "ps aux --sort=-%mem | head -10"

section "TOP CPU PROCESSES"
runsh "ps aux --sort=-%cpu | head -10"

section "ZOMBIE COUNT"
runsh "ps -eo stat | grep -c '^Z' || true"

section "LISTENING PORTS"
runsh "ss -tlnp 2>/dev/null | head -40"

section "RECENT FAILED LOGINS"
runsh "lastb -n 30 2>/dev/null | head -30"

section "AUTH ERRORS (last 30 matches)"
runsh "tail -500 /var/log/secure 2>/dev/null | grep -iE 'fail|invalid|denied' | tail -30"

section "NGINX 4XX/5XX (last hour, last 30)"
runsh "awk -v d=\"\$(date -d '1 hour ago' '+%d/%b/%Y:%H')\" '\$0 ~ d && (\$9 ~ /^[45]/)' /var/log/nginx/access.log 2>/dev/null | tail -30"

section "CROWDSEC ACTIVE DECISIONS"
runsh "cscli decisions list -o human 2>/dev/null | head -20"

section "FAIL2BAN STATUS"
runsh "fail2ban-client status 2>/dev/null"

section "MAGENTO EXCEPTIONS (last 40 lines)"
runsh "tail -40 $MAGE_ROOT/var/log/exception.log 2>/dev/null"

section "MAGENTO SYSTEM LOG (last 30 lines)"
runsh "tail -30 $MAGE_ROOT/var/log/system.log 2>/dev/null"

section "MAGENTO CACHE STATUS"
runsh "cd $MAGE_ROOT && sudo -u nginx php bin/magento cache:status 2>/dev/null"

section "BACKUP LOG MTIME"
runsh "stat -c '%y %n' $MAGE_ROOT/var/log/backups.log 2>/dev/null"

section "MARIADB PING"
# DB_USER / DB_PASS are exported via /etc/environment by the manifest.
runsh ": \"\${DB_USER:=}\"; : \"\${DB_PASS:=}\"; mysqladmin -hDB_MASTER -u\"\$DB_USER\" -p\"\$DB_PASS\" ping 2>&1"

section "REDIS PING"
runsh "redis-cli -s /tmp/redis.sock ping 2>/dev/null || redis-cli ping"

section "RECENT SUDO USAGE"
runsh "tail -200 /var/log/secure 2>/dev/null | grep -i 'sudo' | tail -10"

section "END"
