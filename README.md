# Standalone Magento 2 Hosting Environment for Jelastic

A self-healing JPS package that deploys a hardened, production-ready Magento 2 environment with automatic service recovery, security hardening, and monitoring across all nodes.

## Architecture

| Node | Software | Cloudlets | Disk |
|------|----------|-----------|------|
| **AppServer (cp)** | NGINX + PHP-FPM 8.3 | 74 | - |
| **Database (sqldb)** | MariaDB 11.4 LTS | 28 | 200G |
| **Sessions (nosqldb)** | Redis 7.2 | 28 | 10G |
| **Search (es)** | OpenSearch 2.19.5 / 3.6.0 | 28 | 100G |

The AppServer also runs a local Redis instance for Magento cache (separate from the session Redis node).

## Install Settings

| Field | Description |
|-------|-------------|
| Backup Email | Used for fail2ban alerts and backup failure notifications |
| PHP Version | Currently 8.3.24 on AlmaLinux 9 |
| OpenSearch Version | 2.19.5 (recommended for Magento 2.4.8) or 3.6.0 (for 2.4.9+) |

## Self-Healing & Monitoring

Every node has health checks that automatically detect and recover from failures:

### AppServer (cp) - Monit

| Service | Check | Recovery |
|---------|-------|----------|
| NGINX | HTTP request to `/health_check.php` | Restart, circuit breaker after 5 failures |
| PHP-FPM | Unix socket connectivity | Restart, circuit breaker after 5 failures |
| Redis (local cache) | Port 6379 connectivity | Restart, alert on memory > 512MB |

All three monitored via Monit with memory thresholds (NGINX > 1GB, PHP-FPM > 3GB triggers restart).

### Database (sqldb) - Cron Health Check

- `check_mariadb.sh` runs every 2 minutes
- Uses `mysqladmin ping` to verify responsiveness
- Restarts MariaDB after 3 consecutive failures
- Logs to `/var/log/mysql/healthcheck.log`

### Sessions (nosqldb) - Cron Health Check

- `check_redis_sessions.sh` runs every 2 minutes
- Uses `redis-cli ping` to verify responsiveness
- Restarts Redis after 3 consecutive failures
- Logs to `/var/log/redis_healthcheck.log`

### Search (es) - Cron Health Check

- `check_opensearch.sh` runs every 2 minutes
- Checks HTTP response on `localhost:9200/_cluster/health`
- Detects both unresponsive service AND red cluster status
- Restarts via supervisorctl after 3 consecutive failures
- Logs to `/var/log/opensearch/healthcheck.log`

### Magento Cron Monitor

- `check_magento_cron.sh` runs every 5 minutes on the AppServer
- Queries `cron_schedule` table for recent successful executions
- Alerts via email if no successful cron in last 15 minutes
- Attempts to restart cron if process not found
- Cleans up old `cron_schedule` entries (> 7 days) to prevent table bloat
- Kills stuck jobs running for more than 1 hour

## Security Hardening

### SSH Lockdown

All external SSH (port 22) is blocked on every node at provisioning time via iptables. Only Jelastic internal networks (RFC1918) are permitted, so SSH access is exclusively through the Jelastic web SSH portal.

### NGINX

- **Rate limiting** on admin panel (5r/s), customer login (2r/s), and REST/GraphQL API (10r/s)
- **Connection limiting** at 50 concurrent connections per IP
- **Security headers**: `X-Content-Type-Options`, `X-XSS-Protection`, `Referrer-Policy`, `Permissions-Policy`, `X-Frame-Options`
- **PHP execution whitelisting** - only `index.php`, `get.php`, `static.php`, `health_check.php`, and error handlers can execute
- **Banned locations** - `.php`, `.phtml`, `.htaccess`, `.htpasswd`, `.git`, `.user.ini` all denied
- **php-fpm status/ping** restricted to localhost only
- **Static assets** served with immutable cache headers (1 year)
- Site config aligned with the official Magento 2.4 `nginx.conf.sample`

### PHP Hardening

- `expose_php = Off` - hides PHP version from headers
- `allow_url_include = Off` - prevents remote file inclusion
- `open_basedir` restricted to Magento root and `/tmp`
- `disable_functions` - `passthru`, `proc_open`, `popen`
- Secure session cookies: `httponly`, `secure`, `samesite=Lax`, `strict_mode`
- `request_terminate_timeout = 600s` - kills runaway PHP processes
- `request_slowlog_timeout = 30s` - logs slow requests to `/var/log/nginx/php-fpm.slow.log`

### MariaDB Hardening

- `skip-symbolic-links` - prevents symlink attacks
- `local-infile = 0` - disables `LOAD DATA LOCAL`
- phpMyAdmin access denied by default
- Error logging to `/var/log/mysql/error.log`

### OpenSearch Hardening

- Demo config disabled (`DISABLE_INSTALL_DEMO_CONFIG=true`)
- Security plugin disabled (internal network only, no public exposure)
- JVM heap set via environment variable (`-Xms4g -Xmx4g`)

### Firewall / Intrusion Prevention

**fail2ban** with three filter sets:

| Filter | Trigger | Ban |
|--------|---------|-----|
| `nginx-badurls` | Probing for phpMyAdmin, .env files, WordPress paths, etc. | 3 hits = ban |
| `nginx-search` | Search abuse (catalog search flooding) | 10 hits in 15min = 10min ban |
| `nginx-magento-admin` | Admin/customer login brute-force | 5 hits in 5min = 1 hour ban |

All filters auto-update daily from the repo via `fail2banUpdate.sh`.

### SSL

Let's Encrypt SSL addon is installed automatically at provisioning with webroot validation.

## Log Rotation

All nodes have logrotate configured to prevent disk exhaustion:

| Node | Logs | Rotation |
|------|------|----------|
| AppServer | nginx access/error, php-fpm, slowlog | Daily, 14 days, compressed |
| OpenSearch | opensearch.log | Daily, 7 days, compressed |
| MariaDB | error.log | Weekly, 4 weeks, compressed |

## Services & Tools

### Monit (AppServer)

- Port 2812
- Username/password displayed at environment creation
- Monitors NGINX, PHP-FPM, and local Redis

### GoAccess (AppServer)

- Access at `BASE_URL/site_report`
- Protected with HTTP basic auth (credentials displayed at creation)
- Updated daily via cron
- Requires `/var/www/webroot/ROOT/go_access_exclude_list.txt` with URLs to ignore:

```
/media
/static
/nginx_status
```

### AWS CLI v2 (AppServer)

Installed for S3 backup operations. Configure credentials with `aws configure`.

### Node.js 20 LTS (AppServer)

Installed for Hyva theme Tailwind CSS compilation. Run `npm ci` in your theme's `web/tailwind` directory.

## Post-Deploy Tasks

1. Stop and start the entire environment (ensures all services start correctly with supervisord)
2. Bind your domain
3. Verify SSL certificate issued correctly via the Let's Encrypt addon

## Cron Schedule Summary

| Node | Script | Schedule |
|------|--------|----------|
| AppServer | `check_magento_cron.sh` | Every 5 min |
| AppServer | `fail2banUpdate.sh` | Daily 5AM |
| AppServer | GoAccess report | Daily 1AM |
| AppServer | Media S3 backup | Daily 5AM |
| AppServer | Clear import dir | Weekly Sunday 8:05AM |
| Database | `check_mariadb.sh` | Every 2 min |
| Sessions | `check_redis_sessions.sh` | Every 2 min |
| Search | `check_opensearch.sh` | Every 2 min |
