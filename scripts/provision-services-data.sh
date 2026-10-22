#!/usr/bin/env bash
# provision-services-data.sh - Idempotent hardening + self-healing for the
# data nodes of the services env. One script, role chosen by argument so the
# add-on manifest stays short:
#
#   provision-services-data.sh db      (nodeGroup sqldb, MariaDB)
#   provision-services-data.sh redis   (nodeGroup nosqldb, Redis sessions)
#   provision-services-data.sh es      (nodeGroup es, OpenSearch docker)
#
# Never restarts a healthy running service unless its config was missing.
# Env: REPO_REF (default main)
set -euo pipefail

ROLE="${1:?role: db|redis|es}"
REPO_REF="${REPO_REF:-main}"
REPO_BASE="https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/${REPO_REF}"
LOG=/var/log/services-provision.log

log() { echo "[provision-$ROLE] $*" | tee -a "$LOG"; }
die() { echo "[provision-$ROLE] FATAL: $*" | tee -a "$LOG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
touch "$LOG"

fetch() {
  curl -fsSL "$REPO_BASE/$1" -o "$2.tmp" || die "download failed: $1"
  mv "$2.tmp" "$2"
}

cron_root() { # cron_root 'line'
  touch /var/spool/cron/root
  grep -qF -- "$1" /var/spool/cron/root || echo "$1" >> /var/spool/cron/root
  chmod 0600 /var/spool/cron/root
}

role_db() {
  if [ -f /etc/httpd/conf.d/phpMyAdmin-jel.conf ]; then
    sed -i 's/Require all granted/Require all denied/g' /etc/httpd/conf.d/phpMyAdmin-jel.conf
  fi
  # Envs built from the old monolith manifest already carry this block (no
  # marker line) - match on a directive so a live DB is not restarted twice.
  if ! grep -qE '^(# proxiblue-hardening|skip-symbolic-links)' /etc/my.cnf; then
    log "appending hardening block to /etc/my.cnf"
    cat >> /etc/my.cnf <<'DBEOF'

# proxiblue-hardening
[mysqld]
skip-symbolic-links = 1
local-infile = 0
bind-address = 0.0.0.0
max_allowed_packet = 128M
log_error = /var/log/mysql/error.log
DBEOF
    mkdir -p /var/log/mysql
    chown mysql:mysql /var/log/mysql
    # Jelastic stacks differ: mariadb-dockerized -> mysql/mariadb, mysql8 -> mysqld
    systemctl restart mysql >>"$LOG" 2>&1 \
      || systemctl restart mariadb >>"$LOG" 2>&1 \
      || systemctl restart mysqld >>"$LOG" 2>&1 \
      || die "could not restart the database service"
  fi
  fetch configs/logrotate/mariadb /etc/logrotate.d/mariadb
  fetch configs/healthchecks/check_mariadb.sh /root/check_mariadb.sh
  chmod +x /root/check_mariadb.sh
  cron_root "*/2 * * * * /bin/bash /root/check_mariadb.sh"
  log "mariadb: $(mysqladmin ping 2>&1 | tail -1)"
}

role_redis() {
  local changed=0
  local tmp; tmp="$(mktemp)"
  fetch configs/redis/redis.conf "$tmp"
  if ! cmp -s "$tmp" /etc/redis.conf; then
    cp "$tmp" /etc/redis.conf; changed=1
  fi
  rm -f "$tmp"
  mkdir -p /etc/systemd/system/redis.service.d
  if [ ! -f /etc/systemd/system/redis.service.d/restart.conf ]; then
    fetch configs/restart.conf /etc/systemd/system/redis.service.d/restart.conf
    systemctl daemon-reload; changed=1
  fi
  if [ "$changed" -eq 1 ]; then
    log "redis config changed, restarting (sessions will survive: RDB persisted)"
    systemctl restart redis >>"$LOG" 2>&1
  fi
  fetch configs/healthchecks/check_redis_sessions.sh /root/check_redis_sessions.sh
  chmod +x /root/check_redis_sessions.sh
  cron_root "*/2 * * * * /bin/bash /root/check_redis_sessions.sh"
  log "redis: $(redis-cli ping 2>&1 | tail -1)"
}

role_es() {
  local osdir=/usr/share/opensearch
  local need_restart=0
  rpm -q supervisor >/dev/null 2>&1 || { yum install -y epel-release supervisor >>"$LOG" 2>&1; systemctl enable supervisord >>"$LOG" 2>&1; }
  mkdir -p /var/log/supervisor /var/log/opensearch /var/lib/opensearch
  chown opensearch:opensearch /var/lib/opensearch
  [ -e /usr/java/latest ] || ln -sf "$osdir/jdk" /usr/java/latest
  [ -f /etc/supervisord.conf ] && grep -q opensearch /etc/supervisord.conf \
    || fetch configs/es/supervisord.conf /etc/supervisord.conf
  for plugin in analysis-icu analysis-phonetic; do
    if ! "$osdir/bin/opensearch-plugin" list 2>/dev/null | grep -qx "$plugin"; then
      log "installing OpenSearch plugin $plugin"
      "$osdir/bin/opensearch-plugin" install -b "$plugin" >>"$LOG" 2>&1
      need_restart=1
    fi
  done
  chattr -i "$osdir/config/opensearch.yml" 2>/dev/null || true
  if ! grep -q '^plugins.security.disabled: true' "$osdir/config/opensearch.yml" 2>/dev/null; then
    log "writing opensearch.yml + jvm.options"
    fetch configs/es/opensearch.yml "$osdir/config/opensearch.yml"
    fetch configs/es/jvm.options   "$osdir/config/jvm.options"
    need_restart=1
  fi
  fetch configs/logrotate/opensearch /etc/logrotate.d/opensearch
  fetch configs/healthchecks/check_opensearch.sh /root/check_opensearch.sh
  chmod +x /root/check_opensearch.sh
  cron_root "*/2 * * * * /bin/bash /root/check_opensearch.sh"
  if [ "$need_restart" -eq 1 ]; then
    log "restarting OpenSearch (plugin/config change)"
    supervisorctl restart opensearch >>"$LOG" 2>&1 || true
  fi
  log "opensearch: HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:9200/_cluster/health || true)"
}

case "$ROLE" in
  db)    role_db ;;
  redis) role_redis ;;
  es)    role_es ;;
  *)     die "unknown role $ROLE" ;;
esac
log "done"
