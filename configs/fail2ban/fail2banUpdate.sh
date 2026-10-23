#!/bin/bash
# Update fail2ban filters and jails from the repo. Profile-aware: the site
# profile (magento|drupal) is read from /etc/phpbox.env, written by
# provision-cp.sh. Runs daily from root's cron and from the add-on button.

ENV_FILE=/etc/phpbox.env
SITE_PROFILE=magento
REPO_REF=main
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
REPO_BASE="https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/${REPO_REF}/configs/fail2ban"

case "$SITE_PROFILE" in
  drupal) JAILS="nginx-badurls nginx-drupal-login" ;;
  *)      JAILS="nginx-badurls nginx-search nginx-magento-admin" ;;
esac

fetch() {
  curl -fsSL "$1" -o "$2.tmp" && mv "$2.tmp" "$2" || { echo "fetch failed: $1" >&2; rm -f "$2.tmp"; return 1; }
}

for j in $JAILS; do
  fetch "${REPO_BASE}/filter.d/$j.conf" "/etc/fail2ban/filter.d/$j.conf"
  fetch "${REPO_BASE}/jail.d/$j.conf"   "/etc/fail2ban/jail.d/$j.conf"
done

systemctl restart fail2ban
