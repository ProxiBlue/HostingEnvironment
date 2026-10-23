#!/usr/bin/env bash
# phpbox - terminal front-end for the ProxiBlue PHP Box add-on.
# Installed to /usr/local/bin/phpbox by provision-cp.sh. Run as root
# ("su -" from nginx with the system password, see "phpbox creds").
#
#   phpbox status             services, versions, DB reachability, last provision result
#   phpbox creds              system / stats / monit passwords
#   phpbox env                persisted settings (/etc/phpbox.env), hosts entries
#   phpbox reapply [REF]      re-run the provisioner (optionally from git ref REF)
#   phpbox fail2ban-update    refresh fail2ban filters/jails from the repo
#   phpbox authorize-key KEY  allow the services monitor to ssh in as nginx
#   phpbox mounts             configured mount list (/etc/phpbox-mounts.txt) vs. what is mounted
#   phpbox log [N]            last N lines of the provision log (default 40)
set -u

ENV_FILE=/etc/phpbox.env
CREDS_FILE=/root/phpbox-credentials.txt
LOG=/var/log/phpbox-provision.log

need_root() { [ "$(id -u)" -eq 0 ] || { echo "run as root (su - , password: phpbox creds)" >&2; exit 1; }; }
load_env() { [ -f "$ENV_FILE" ] && . "$ENV_FILE"; : "${REPO_REF:=main}"; }

c_status() {
  need_root; load_env
  echo "== services"
  for s in nginx php-fpm redis monit fail2ban crond; do
    printf '  %-9s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  echo "== versions"
  echo "  php    $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
  echo "  nginx  $(nginx -v 2>&1 | sed 's/nginx version: //')"
  echo "  redis  $(redis-cli -s /tmp/redis.sock ping 2>&1) (socket) / $(redis-cli -h 127.0.0.1 ping 2>&1) (tcp)"
  echo "== profile ${SITE_PROFILE:-?}  docroot ${DOCROOT:-?}"
  echo "== services env"
  printf '  DB_MASTER  %-16s tcp/3306 %s\n' "${DB_HOST:-}" "$( [ -n "${DB_HOST:-}" ] && (timeout 3 bash -c "</dev/tcp/$DB_HOST/3306" 2>/dev/null && echo open || echo CLOSED) )"
  [ -n "${REDIS_HOST:-}" ] && printf '  RD_MASTER  %-16s %s\n' "$REDIS_HOST" "$(redis-cli -h "$REDIS_HOST" ping 2>&1 | tail -1)"
  [ -n "${ES_HOST:-}" ]    && printf '  ES_MASTER  %-16s HTTP %s\n' "$ES_HOST" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ES_HOST:9200/" || true)"
  echo "== tls"
  if [ -s /var/lib/jelastic/SSL/jelastic.chain ]; then
    printf '  cert: %s\n' "$(openssl x509 -in /var/lib/jelastic/SSL/jelastic.chain -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
  else
    echo "  cert: none in /var/lib/jelastic/SSL"
  fi
  echo "  443: $(ss -tln 2>/dev/null | grep -q ':443 ' && echo listening || echo not listening)"
  echo "== mounts"
  mount | grep -E ' /var/www/' | awk '{print "  "$1" -> "$3" ("$5")"}' || true
  echo "== fail2ban"
  fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:/  jails:/p'
  echo "== last provision"
  echo "  $(grep -E 'provisioned OK|FATAL' "$LOG" 2>/dev/null | tail -1)"
  echo "  web: http://$(hostname -I | awk '{print $1}')/  monit: http://$(hostname -I | awk '{print $1}'):2812 (admin)"
}

c_creds() {
  need_root
  [ -f "$CREDS_FILE" ] || { echo "no $CREDS_FILE yet"; exit 1; }
  grep -vE '^#' "$CREDS_FILE"
  echo "SYSTEM_PASS = root + nginx login; STATS_PASS = /site_report (user stats); MONIT_PASS = :2812 (user admin)"
}

c_env() {
  need_root
  cat "$ENV_FILE" 2>/dev/null || echo "no $ENV_FILE"
  echo "-- /etc/hosts"
  grep -E 'MASTER' /etc/hosts || true
}

c_reapply() {
  need_root; load_env
  local ref="${1:-$REPO_REF}"
  echo "re-provisioning from ref $ref"
  curl -fsSL "https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/$ref/scripts/provision-cp.sh" -o /root/provision-cp.sh || { echo "download failed"; exit 1; }
  chmod +x /root/provision-cp.sh
  REPO_REF="$ref" bash /root/provision-cp.sh
}

c_f2b() { need_root; bash /root/fail2banUpdate.sh && fail2ban-client status; }

c_authorize() {
  need_root
  local key="${1:-}"; [ -n "$key" ] || { echo "usage: phpbox authorize-key 'ssh-ed25519 AAAA...'"; exit 1; }
  local ak=/var/lib/nginx/.ssh/authorized_keys
  install -d -m 0700 -o nginx -g nginx /var/lib/nginx/.ssh
  touch "$ak"; chown nginx:nginx "$ak"; chmod 0600 "$ak"
  grep -qF -- "$key" "$ak" && echo "already present" || { echo "$key" >> "$ak"; echo "added"; }
}

c_mounts() {
  echo "== configured (/etc/phpbox-mounts.txt) - edit, then add-on button 'Apply mounts'"
  grep -vE '^\s*(#|$)' /etc/phpbox-mounts.txt 2>/dev/null || echo "  (none)"
  echo "== autofs map (/etc/autofs.jelastic)"
  sed 's/-fstype=[^ ]* //' /etc/autofs.jelastic 2>/dev/null || echo "  (none)"
  echo "== mounted now"
  mount | grep -E 'nfs|autofs' | awk '{print "  "$1" -> "$3" ("$5")"}' || true
}

c_log() { tail -n "${1:-40}" "$LOG"; }

case "${1:-}" in
  status)          c_status ;;
  creds)           c_creds ;;
  env|services)    c_env ;;
  reapply)         c_reapply "${2:-}" ;;
  fail2ban-update) c_f2b ;;
  authorize-key)   c_authorize "${2:-}" ;;
  mounts)          c_mounts ;;
  log)             c_log "${2:-40}" ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
