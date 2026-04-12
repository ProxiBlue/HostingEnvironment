#!/bin/bash
# Update all fail2ban filters and jails from repo

REPO_BASE="https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/fail2ban"

curl --silent "${REPO_BASE}/filter.d/nginx-badurls.conf" > /etc/fail2ban/filter.d/nginx-badurls.conf
curl --silent "${REPO_BASE}/filter.d/nginx-search.conf" > /etc/fail2ban/filter.d/nginx-search.conf
curl --silent "${REPO_BASE}/filter.d/nginx-magento-admin.conf" > /etc/fail2ban/filter.d/nginx-magento-admin.conf

curl --silent "${REPO_BASE}/jail.d/nginx-badurls.conf" > /etc/fail2ban/jail.d/nginx-badurls.conf
curl --silent "${REPO_BASE}/jail.d/nginx-search.conf" > /etc/fail2ban/jail.d/nginx-search.conf
curl --silent "${REPO_BASE}/jail.d/nginx-magento-admin.conf" > /etc/fail2ban/jail.d/nginx-magento-admin.conf

systemctl restart fail2ban
