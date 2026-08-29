#!/bin/bash
# /usr/local/bin/refresh-cf-ips.sh
# Refresh the CF-IP `geo` block from official published lists.
# Reload nginx only if the list actually changed.
# Preserves manually-added office/dev IPs by parking them under a marker.
#
# Install:  install -m 0755 refresh-cf-ips.sh /usr/local/bin/refresh-cf-ips.sh
# Cron:     0 3 * * 0 root /usr/local/bin/refresh-cf-ips.sh
set -euo pipefail

TARGET_GEO=/etc/nginx/conf.d/cloudflare-geo.conf
TARGET_REALIP=/etc/nginx/conf.d/cloudflare-realip.conf
LOG=/var/log/cf-ip-refresh.log

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

V4=$(curl -sSf --max-time 10 https://www.cloudflare.com/ips-v4) || {
  echo "$TS ABORT: fetch ips-v4 failed" >> "$LOG"; exit 1;
}
V6=$(curl -sSf --max-time 10 https://www.cloudflare.com/ips-v6) || {
  echo "$TS ABORT: fetch ips-v6 failed" >> "$LOG"; exit 1;
}

V4_COUNT=$(printf '%s\n' "$V4" | grep -c '/' || echo 0)
V6_COUNT=$(printf '%s\n' "$V6" | grep -c '/' || echo 0)
if [ "$V4_COUNT" -lt 10 ] || [ "$V6_COUNT" -lt 3 ]; then
  echo "$TS ABORT: sanity check failed v4=$V4_COUNT v6=$V6_COUNT" >> "$LOG"
  exit 1
fi

# Preserve office/dev IPs: everything from the "Office / dev IPs" marker down to
# (but not including) the closing brace.
if [ -f "$TARGET_GEO" ]; then
  OFFICE=$(awk '
    /# Office \/ dev IPs/ { keep=1 }
    keep && /^}/          { exit }
    keep                  { print }
  ' "$TARGET_GEO")
else
  OFFICE="    # Office / dev IPs — ADD PER-DEPLOYMENT below this line."
fi

# Rebuild the geo block
{
  cat <<HDR
# /etc/nginx/conf.d/cloudflare-geo.conf
# Auto-regenerated $TS by refresh-cf-ips.sh
# geo block defining \$cf_allowed = 1 for CF edge / office / dev IPs.
# Consumed by conf.d/includes/cloudflare-allowlist.conf inside each server{}.

geo \$realip_remote_addr \$cf_allowed {
    default 0;

    # Cloudflare edge v4
HDR
  echo "$V4" | awk 'NF {print "    " $0 " 1;"}'
  echo
  echo "    # Cloudflare edge v6"
  echo "$V6" | awk 'NF {print "    " $0 " 1;"}'
  echo
  echo "    # Localhost + Cloudlets internal"
  echo "    127.0.0.1 1;"
  echo "    ::1 1;"
  echo "    10.0.0.0/8 1;"
  echo "    172.16.0.0/12 1;"
  echo "    192.168.0.0/16 1;"
  echo
  echo "$OFFICE"
  echo "}"
} > "${TARGET_GEO}.new"

# Rebuild realip (same CF list — keep in sync)
{
  echo "# Cloudflare real client IP restoration."
  echo "# Auto-regenerated $TS by refresh-cf-ips.sh"
  echo
  echo "$V4" | awk 'NF {print "set_real_ip_from " $0 ";"}'
  echo
  echo "$V6" | awk 'NF {print "set_real_ip_from " $0 ";"}'
  echo
  echo "real_ip_header CF-Connecting-IP;"
  echo "real_ip_recursive on;"
} > "${TARGET_REALIP}.new"

CHANGED=0
if ! diff -q "$TARGET_GEO" "${TARGET_GEO}.new" >/dev/null 2>&1; then
  install -m 0644 "${TARGET_GEO}.new" "$TARGET_GEO"
  CHANGED=1
fi
if ! diff -q "$TARGET_REALIP" "${TARGET_REALIP}.new" >/dev/null 2>&1; then
  install -m 0644 "${TARGET_REALIP}.new" "$TARGET_REALIP"
  CHANGED=1
fi
rm -f "${TARGET_GEO}.new" "${TARGET_REALIP}.new"

if [ "$CHANGED" -eq 1 ]; then
  if nginx -t 2>>"$LOG"; then
    systemctl reload nginx
    echo "$TS reloaded nginx (list changed)" >> "$LOG"
  else
    echo "$TS ABORT: nginx -t failed after regen" >> "$LOG"
    exit 1
  fi
else
  echo "$TS no change" >> "$LOG"
fi
