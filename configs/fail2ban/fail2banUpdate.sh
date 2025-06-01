#!/bin/bash

curl --silent https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/fail2ban/filter.d/nginx-badurls.conf > /etc/fail2ban/filter.d/nginx-badurls.conf
service fail2ban restart

