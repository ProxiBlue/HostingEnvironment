#!/usr/bin/env bash
# le-deploy-hook.sh - deployHook for the Let's Encrypt add-on on a docker-type
# AppServer (addons/letsencrypt-docker.jps). On stack nodes the platform
# installs the issued certificate itself; on a plain docker node the add-on
# only issues it (acme.sh) and leaves it under .../var/lib/jelastic/keys/.
# The add-on fetches this file by URL and runs it as root after every
# issue / renewal. It copies the files where the nginx TLS server expects
# them and switches ssl.conf on if needed.
#
# Can also be run by hand: bash le-deploy-hook.sh
set -u
SSL_DIR=/var/lib/jelastic/SSL
SSL_CONF=/etc/nginx/conf.d/ssl.conf
LOG=/var/log/phpbox-provision.log
log() { echo "[le-deploy-hook] $*" | tee -a "$LOG"; }

# newest fullchain.pem written by the add-on
keys="$(find / -path /proc -prune -o -type f -name fullchain.pem -path '*jelastic/keys*' -printf '%T@ %h\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
[ -n "$keys" ] && [ -s "$keys/privkey.pem" ] || { log "no issued certificate found (fullchain.pem/privkey.pem under */jelastic/keys)"; exit 1; }

install -d -m 0750 "$SSL_DIR"
cp -f "$keys/fullchain.pem" "$SSL_DIR/jelastic.chain"
cp -f "$keys/privkey.pem"   "$SSL_DIR/jelastic.key"
[ -s "$keys/cert.pem" ] && cp -f "$keys/cert.pem" "$SSL_DIR/jelastic.cert"
chmod 0640 "$SSL_DIR"/jelastic.*
chown -R root:nginx "$SSL_DIR"
log "certificate installed from $keys: $(openssl x509 -in "$SSL_DIR/jelastic.chain" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"

if ! { [ -f "$SSL_CONF" ] && grep -qE '^\s*listen\s+.*443' "$SSL_CONF"; }; then
  REPO_REF=main
  [ -f /etc/phpbox.env ] && . /etc/phpbox.env
  curl -fsSL "https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/${REPO_REF:-main}/configs/nginx/ssl.conf.disabled" -o "$SSL_CONF.tmp" \
    && mv "$SSL_CONF.tmp" "$SSL_CONF" || { log "could not fetch ssl.conf template"; exit 1; }
  log "ssl.conf enabled"
fi
nginx -t >>"$LOG" 2>&1 || { log "nginx -t failed, see $LOG"; exit 1; }
systemctl reload nginx || systemctl restart nginx
log "nginx reloaded, https on"
