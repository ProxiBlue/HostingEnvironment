#!/usr/bin/env bash
# provision-services-cp.sh - Idempotent provisioning of the services env's
# nginx node (Resource Server "AppServer", nodeGroup cp). Hosts:
#   - n8n (self-hosted) with the Server Monitor workflow, snapshotting the
#     local services AND the PHP box over ssh,
#   - the Magento cron health check (DB is local to this env),
#   - the ssh identity (user n8n) the PHP box must authorise.
#
# Run by addons/services-addon.jps on install, after a redeploy of this node,
# and from the "Re-apply" button.
#
# Inputs (env): PHPBOX_HOST DB_HOST REDIS_HOST ES_HOST DB_USER DB_PASS
#               ALERT_EMAIL N8N_DOMAIN N8N_PUBLIC_PORT N8N_ALLOWED_IPS
#               GEMINI_API_KEY MONITOR_SCHEDULE REPO_REF
# Persisted to /etc/magento-monitor.env; later runs may omit them.
set -euo pipefail

ENV_FILE=/etc/magento-monitor.env
LOG=/var/log/services-provision.log
N8N_USER=n8n
N8N_HOME=/var/lib/n8n
N8N_KEY=$N8N_HOME/.ssh/id_ed25519

log() { echo "[provision-services-cp] $*" | tee -a "$LOG"; }
die() { echo "[provision-services-cp] FATAL: $*" | tee -a "$LOG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
touch "$LOG"

load_env() {
  if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r k v; do
      [ -z "$k" ] && continue
      case "$k" in \#*) continue ;; esac
      v="${v%\"}"; v="${v#\"}"
      [ -z "${!k:-}" ] && export "$k=$v"
    done < "$ENV_FILE"
  fi
  : "${REPO_REF:=main}"
  : "${DB_NAME:=magento}"
  : "${PHPBOX_HOST:=}"
  : "${GEMINI_API_KEY:=}"
  : "${MONITOR_SCHEDULE:=0 */4 * * *}"
  : "${N8N_PUBLIC_PORT:=8443}"
  : "${N8N_ALLOWED_IPS:=}"
  : "${N8N_DOMAIN:=$(hostname -f)}"
  : "${REDIS_HOST:=}"
  : "${ES_HOST:=}"
  for v in DB_HOST DB_USER DB_PASS ALERT_EMAIL; do
    [ -n "${!v:-}" ] || die "$v not set and not in $ENV_FILE"
  done
  [ -n "$REDIS_HOST" ] || log "WARNING: no Redis node in this env yet (REDIS_HOST empty)"
  [ -n "$ES_HOST" ]    || log "WARNING: no OpenSearch node in this env yet (ES_HOST empty)"
  REPO_BASE="https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/${REPO_REF}"
}

persist_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
# Written by provision-services-cp.sh. Edit, then "Re-apply" on the add-on.
PHPBOX_HOST="$PHPBOX_HOST"
DB_HOST="$DB_HOST"
REDIS_HOST="$REDIS_HOST"
ES_HOST="$ES_HOST"
DB_NAME="$DB_NAME"
DB_USER="$DB_USER"
DB_PASS="$DB_PASS"
ALERT_EMAIL="$ALERT_EMAIL"
N8N_DOMAIN="$N8N_DOMAIN"
N8N_PUBLIC_PORT="$N8N_PUBLIC_PORT"
N8N_ALLOWED_IPS="$N8N_ALLOWED_IPS"
GEMINI_API_KEY="$GEMINI_API_KEY"
MONITOR_SCHEDULE="$MONITOR_SCHEDULE"
REPO_REF="$REPO_REF"
EOF
  umask 022
}

fetch() {
  curl -fsSL "$REPO_BASE/$1" -o "$2.tmp" || die "download failed: $1"
  mv "$2.tmp" "$2"
}

set_host() {
  sed -i "/[[:space:]]$1\$/d" /etc/hosts
  echo "$2 $1" >> /etc/hosts
}

install_packages() {
  rpm -q epel-release >/dev/null 2>&1 || yum install -y epel-release >>"$LOG" 2>&1
  local missing=""
  for p in mariadb redis mailx curl; do
    rpm -q "$p" >/dev/null 2>&1 || command -v "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    log "installing:$missing"
    # shellcheck disable=SC2086
    yum install -y $missing >>"$LOG" 2>&1 || log "WARNING: some packages failed:$missing"
  fi
  # Node 22 is handled by install_n8n.sh (require_node).
}

hosts() {
  set_host DB_MASTER "$DB_HOST"
  [ -n "$REDIS_HOST" ]  && set_host RD_MASTER "$REDIS_HOST"
  [ -n "$ES_HOST" ]     && set_host ES_MASTER "$ES_HOST"
  [ -n "$PHPBOX_HOST" ] && set_host PHPBOX "$PHPBOX_HOST"
  return 0
}

install_n8n() {
  log "running install_n8n.sh (services mode)"
  local tmp; tmp="$(mktemp)"
  fetch configs/n8n/install_n8n.sh "$tmp"
  export N8N_DOMAIN N8N_PUBLIC_PORT N8N_ALLOWED_IPS GEMINI_API_KEY MONITOR_SCHEDULE ALERT_EMAIL
  export REPO_BASE_URL="$REPO_BASE/configs/n8n"
  export SNAPSHOT_SOURCE_FILE=n8n-services-snapshot.sh
  bash "$tmp" 2>&1 | tee -a "$LOG"
  rm -f "$tmp"
}

monitor_ssh_key() {
  # Identity the PHP box authorises for nginx@PHPBOX (snapshot + cron kick).
  install -d -m 0700 -o "$N8N_USER" -g "$N8N_USER" "$N8N_HOME/.ssh"
  if [ ! -f "$N8N_KEY" ]; then
    log "generating monitor ssh key $N8N_KEY"
    runuser -u "$N8N_USER" -- ssh-keygen -q -t ed25519 -N '' -C "magento-monitor@$(hostname -f)" -f "$N8N_KEY"
  fi
  # /var/lib/n8n is in the unit's ReadWritePaths, so ssh can write known_hosts.
  touch "$N8N_HOME/.ssh/known_hosts"
  chown -R "$N8N_USER:$N8N_USER" "$N8N_HOME/.ssh"
  chmod 0600 "$N8N_KEY" "$N8N_HOME/.ssh/known_hosts"
}

magento_cron_check() {
  fetch configs/healthchecks/check_magento_cron.sh /root/check_magento_cron.sh
  chmod +x /root/check_magento_cron.sh
  touch /var/spool/cron/root
  grep -qF 'check_magento_cron.sh' /var/spool/cron/root \
    || echo "*/5 * * * * /bin/bash /root/check_magento_cron.sh" >> /var/spool/cron/root
  chmod 0600 /var/spool/cron/root
}

verify() {
  systemctl is-active --quiet n8n || die "n8n not active"
  log "VERIFY: mysql ping -> $(mysqladmin -h "$DB_HOST" -u"$DB_USER" -p"$DB_PASS" ping 2>&1 | tail -1)"
  [ -n "$REDIS_HOST" ] && log "VERIFY: redis ping -> $(redis-cli -h "$REDIS_HOST" ping 2>&1 | tail -1)"
  [ -n "$ES_HOST" ]    && log "VERIFY: opensearch -> HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$ES_HOST:9200/_cluster/health" || true)"
  if [ -n "$PHPBOX_HOST" ]; then
    if runuser -u "$N8N_USER" -- ssh -i "$N8N_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new "nginx@$PHPBOX_HOST" true 2>>"$LOG"; then
      log "VERIFY: ssh nginx@$PHPBOX_HOST OK"
    else
      log "VERIFY: ssh nginx@$PHPBOX_HOST FAILED - authorise this key on the PHP box add-on:"
      log "  $(cat "$N8N_KEY.pub")"
    fi
  fi
}

main() {
  load_env
  log "start (REPO_REF=$REPO_REF, PHPBOX=$PHPBOX_HOST, DB=$DB_HOST)"
  persist_env
  install_packages
  hosts
  install_n8n
  monitor_ssh_key
  magento_cron_check
  verify
  log "done. monitor public key:"
  cat "$N8N_KEY.pub" | tee -a "$LOG"
}

main "$@"
