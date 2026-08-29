#!/bin/bash
# /usr/local/bin/refresh-cf-ips.sh
# Refresh Cloudflare IP allowlist from official published lists.
# Reload nginx only if the list actually changed.
# Preserves manually-added office/dev IPs by parking them under a marker.
#
# Install:  install -m 0755 refresh-cf-ips.sh /usr/local/bin/refresh-cf-ips.sh
# Cron:     0 3 * * 0 root /usr/local/bin/refresh-cf-ips.sh
set -euo pipefail

TARGET_ALLOWLIST=/etc/nginx/conf.d/cloudflare-allowlist.conf
TARGET_REALIP=/etc/nginx/conf.d/cloudflare-realip.conf
LOG=/var/log/cf-ip-refresh.log

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Pull official lists
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

# Preserve any office/dev allow lines (anything AFTER the "Localhost + Cloudlets internal" block
# and BEFORE the final "deny all;")
if [ -f "$TARGET_ALLOWLIST" ]; then
  OFFICE_IPS=$(awk '
    /# Office \/ dev IPs/,/^deny all;/ { print }
  ' "$TARGET_ALLOWLIST" | sed '/^deny all;/d')
else
  OFFICE_IPS="# Office / dev IPs — add here"
fi

# Rebuild allowlist
{
  echo "# /etc/nginx/conf.d/cloudflare-allowlist.conf"
  echo "# Auto-regenerated $TS by refresh-cf-ips.sh"
  echo "# Include INSIDE each server{} that must accept ONLY Cloudflare-proxied traffic."
  echo
  echo "# Cloudflare edge (v4)"
  echo "$V4" | awk 'NF {print "allow " $0 ";"}'
  echo
  echo "# Cloudflare edge (v6)"
  echo "$V6" | awk 'NF {print "allow " $0 ";"}'
  echo
  echo "# Localhost + Cloudlets internal"
  echo "allow 127.0.0.1;"
  echo "allow ::1;"
  echo "allow 10.0.0.0/8;"
  echo "allow 172.16.0.0/12;"
  echo "allow 192.168.0.0/16;"
  echo
  echo "$OFFICE_IPS"
  echo
  echo "# Everyone else: 403 before Magento is touched"
  echo "deny all;"
} > "${TARGET_ALLOWLIST}.new"

# Rebuild realip too (same CF list — keep in sync)
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

# Diff-only reload — skip if nothing changed
CHANGED=0
if ! diff -q "$TARGET_ALLOWLIST" "${TARGET_ALLOWLIST}.new" >/dev/null 2>&1; then
  install -m 0644 "${TARGET_ALLOWLIST}.new" "$TARGET_ALLOWLIST"
  CHANGED=1
fi
if ! diff -q "$TARGET_REALIP" "${TARGET_REALIP}.new" >/dev/null 2>&1; then
  install -m 0644 "${TARGET_REALIP}.new" "$TARGET_REALIP"
  CHANGED=1
fi
rm -f "${TARGET_ALLOWLIST}.new" "${TARGET_REALIP}.new"

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
