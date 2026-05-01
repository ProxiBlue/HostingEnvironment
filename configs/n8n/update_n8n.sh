#!/usr/bin/env bash
# update_n8n.sh - In-place update of the n8n npm package + restart.
# Does not touch /etc/n8n/n8n.env, /var/lib/n8n, the snapshot helper, or the
# nginx vhost - re-run install_n8n.sh if you need those refreshed too.

set -euo pipefail

log() { echo "[update_n8n] $*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then echo "must run as root" >&2; exit 1; fi
}

main() {
  require_root
  log "updating n8n via npm"
  npm install -g --omit=dev n8n@latest
  log "restarting n8n.service"
  systemctl restart n8n.service
  log "update complete"
}

main "$@"
