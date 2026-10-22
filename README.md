# Magento 2 Hosting Environment for Jelastic / Virtuozzo Application Platform

Two environments, two add-ons. The PHP box is disposable; the services are not.

```
┌─ PHP environment ───────────────┐     ┌─ Services environment ("Resource Server") ─┐
│ AppServer  (cp, docker          │     │ nginx node  (cp)   n8n, cron health check    │
│   jelastic/nginxphp:<tag>)      │────▶│ MariaDB     (sqldb)                          │
│   nginx, php-fpm, local redis   │     │ Redis       (nosqldb)  sessions              │
│   fail2ban, monit, goaccess     │◀────│ OpenSearch  (es)                             │
│   add-on: Magento PHP Box       │ ssh │ NFS         (storage)  media                 │
└─────────────────────────────────┘     │ add-on: Magento Services                     │
                                        └──────────────────────────────────────────────┘
```

| File | Type | Installs onto |
|------|------|---------------|
| `manifest.jps` | `install` | New PHP environment: one docker `cp` node, then installs the PHP Box add-on |
| `addons/phpbox-addon.jps` | `update` | `cp` layer of a PHP environment |
| `addons/services-addon.jps` | `update` | `cp` layer of the services environment (reaches `sqldb`/`nosqldb`/`es` by group) |

## Why add-ons

A PHP update used to mean a new environment: slow, and the external IP changed.
Now PHP is updated in place with the dashboard's **Redeploy Containers** dialog.
Redeploy keeps the volumes (`/var/www/webroot/ROOT`, `/var/www/webroot/nfs`) and
the paths in `/etc/jelastic/redeploy.conf` (`/etc/php.d/`, `/etc/php-fpm.conf`,
`/var/spool/cron/nginx`, `/var/lib/nginx/.ssh/`) and wipes everything else:
`/etc/nginx`, yum packages, root cron, `/etc/hosts`, monit, fail2ban.

The PHP Box add-on hooks `onAfterRedeployContainer` and re-runs
`scripts/provision-cp.sh`, so the box is fully configured again before the
dialog closes. The Let's Encrypt add-on does the same for its certificate.

## Install order

### 1. Services environment

Already exists (`lcd-live`). Apply the add-on once:

1. Dashboard → **Import** → **URL** →
   `https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/addons/services-addon.jps`
2. Pick the services environment. Fill: Magento DB user/password, alert
   email, n8n allowlist/port, Gemini key (optional). Leave *PHP box internal
   IP* blank if the PHP env does not exist yet.
3. Success text lists the internal IPs of DB / Redis / OpenSearch - needed
   for step 2.
4. Add-ons tab on the nginx node → **Show monitor SSH key** → copy.

Environments that lack a Redis or OpenSearch layer (ehop: nginxphp + mysql8 +
storage only) get them created by the add-on (`addNodes`, layers `nosqldb` /
`es`, OpenSearch version chosen in the dialog). Data provisioning skips
layers that do not exist. MySQL 8 and MariaDB are both handled.

What it does: MariaDB/MySQL hardening + `check_mariadb.sh`, Redis config +
`check_redis_sessions.sh`, OpenSearch plugins/config + `check_opensearch.sh`
(each node only restarts if its config actually changed), n8n with the
`Server Monitor` workflow on the nginx node, Magento cron health check from
the nginx node (DB is local; `cron:run` kicked on the PHP box over SSH).

### 2. PHP environment

New env: **Import** → **URL** → `.../main/manifest.jps`. Pick PHP tag, enter
the three services IPs, alert email, paste the monitor key.

Existing env (e.g. `newphplive`): **Import** → **URL** →
`.../main/addons/phpbox-addon.jps`, pick the env, same fields. Test on a
**clone** first - the provisioner rewrites `/etc/nginx/nginx.conf`,
`/etc/php.d/*`, fail2ban and monit (it never touches
`conf.d/SITES_ENABLED/`, `conf.d/CORS/`, `ssl.conf` or `.htpasswd` once they
exist).

Then: bind domain, deploy code, install the **Let's Encrypt** add-on on the
`cp` layer (webroot on, path `/var/www/webroot/ROOT/pub`, fallback to X1 on).
`nossl.conf` serves `/.well-known/acme-challenge/` for the webroot check.

Back on the services add-on: **Configure** → set *PHP box internal IP* so the
remote snapshot and cron kick know where to go.

## Updating PHP

1. PHP env → AppServer layer → **Redeploy Containers** → choose tag → confirm.
2. Wait for the add-on's `onAfterRedeployContainer` to finish
   (`/var/log/phpbox-provision.log`, last line `provisioned OK`).
3. `php -v`, `curl -I https://domain/`, check monit on `:2812`.

Nothing else changes: IP, certificate, crontab, code, media.

`/etc/php.d/` survives the redeploy, which is why the provisioner regenerates
it and drops any `extension=` line whose `.so` does not exist in the new
image (imap gone in 8.4, opcache built in from 8.5).

Jelastic publishes PHP patch images a few weeks after php.net. The
`docker/nginxphp/` image + `.github/workflows/nginxphp-image.yml` rebuild PHP
from source on the newest Jelastic base and publish
`ghcr.io/proxiblue/nginxphp:<tag>`; add ghcr as a custom registry in the
Redeploy dialog to use it. Not yet proven on a real redeploy.

## Add-on buttons

**Magento PHP Box** (PHP env, `cp` layer)

| Button | Does |
|--------|------|
| Re-apply configuration | Re-runs `provision-cp.sh` with the stored settings |
| Update fail2ban filters | Pulls filters/jails from the repo, restarts fail2ban |
| Authorize monitor key | Adds a public key to `nginx`'s `authorized_keys` |
| Show credentials | Prints `/root/phpbox-credentials.txt` (system, stats, monit passwords) |

**Magento Services** (services env, `cp` layer)

| Button | Does |
|--------|------|
| Add missing Redis / OpenSearch nodes | `addNodes` for absent `nosqldb` / `es` layers |
| Re-apply configuration | Re-provisions all nodes |
| Configure | Edit settings (PHP box IP, DB creds, n8n, schedule) and re-apply to the nginx node |
| Show monitor SSH key | Prints the key to authorise on the PHP box |
| Update n8n | `npm install -g n8n@latest` + restart |

Pin **Config repo ref** to a commit sha while testing: raw.githubusercontent
caches `main` for ~5 minutes after a push.

## What lives where

**PHP box** - everything that must see the local kernel, sockets or logs:
nginx + php-fpm (`configs/nginx`, `configs/php`), local Redis for Magento
cache on `/tmp/redis.sock`, fail2ban (`nginx-badurls`, `nginx-search`,
`nginx-magento-admin`, auto-updated daily), monit (nginx, php-fpm, redis;
port 2812), logrotate, GoAccess daily report at `/site_report` (basic auth
`stats`), S3 media backup cron, Node.js 22 (Hyva/Tailwind), AWS CLI v2,
`n8n-server-snapshot.sh` (read-only collector the services node calls over
SSH as `nginx` via a one-line sudoers rule).

**Services nginx node** - n8n (`configs/n8n/`, SQLite, nginx-proxied on the
chosen port behind an IP allowlist), `n8n-services-snapshot.sh` (local
DB/Redis/OpenSearch health + the PHP box snapshot over SSH, same path as the
local collector so the shipped workflow is unchanged),
`check_magento_cron.sh` every 5 min, config in `/etc/magento-monitor.env`.

**Data nodes** - healthcheck cron every 2 min, restart after 3 failures
(`configs/healthchecks/`), logrotate, hardening (`skip-symbolic-links`,
`local-infile=0`, phpMyAdmin denied; OpenSearch security plugin off, single
node, `analysis-icu` + `analysis-phonetic` for ElasticSuite).

Persisted state on the PHP box across redeploys (added to `redeploy.conf` by
the provisioner): `/etc/phpbox.env`, `/root/phpbox-credentials.txt`,
`/root/.ssh/`, `/etc/nginx/.htpasswd`, `/etc/nginx/conf.d/SITES_ENABLED/`,
`/etc/nginx/conf.d/CORS/`, `/var/spool/cron/root`, `/var/lib/redis/`.

## Security notes

- PHP: `expose_php=Off`, `allow_url_include=Off`, `open_basedir` limited to
  the Magento root, `/tmp`, the composer cache and the PHP binary path,
  `disable_functions=passthru` (`proc_open`/`popen` stay: Composer and
  `setup:di:compile` need them), secure session cookies,
  `request_terminate_timeout=600s`, slowlog at 30s.
- nginx: rate limits on admin (30r/s), customer login (2r/s), REST/GraphQL
  (10r/s); 50 connections per IP; security headers; PHP execution only for
  `index.php`, `get.php`, `static.php`, `health_check.php`, error handlers;
  dotfiles and `.php` under `media/` denied; php-fpm status/ping localhost
  only; static assets immutable for a year.
- MariaDB 12.x needs `patches/composer/allow-mariadb-12.patch` in the Magento
  project (adds `^12\.` to the SqlVersionProvider DI config).

## Verification after provisioning

PHP box:

```bash
tail -3 /var/log/phpbox-provision.log           # last line: "... provisioned OK"
php -i | grep -E 'disable_functions|open_basedir' # passthru only; composer cache + /usr/lib64/jelastic_php present
php -r 'echo 1;' 2>&1 | head -1                   # no startup warnings
curl -s -o /dev/null -w '%{http_code}\n' https://DOMAIN/media/customer/test.php   # 403
systemctl is-active nginx php-fpm redis monit fail2ban
cat /etc/jelastic/redeploy.conf | sed -n '/CUSTOM/,/SYSTEM/p'
```

Services nginx node:

```bash
tail -3 /var/log/services-provision.log
systemctl is-active n8n
sudo -u n8n ssh -i /var/lib/n8n/.ssh/id_ed25519 -o BatchMode=yes nginx@PHPBOX true && echo ssh-ok
sudo /usr/local/bin/n8n-server-snapshot.sh | head -40
```

Data nodes: `/var/log/mysql/healthcheck.log`, `/var/log/redis_healthcheck.log`,
`/var/log/opensearch/healthcheck.log`; `opensearch-plugin list` shows
`analysis-icu` and `analysis-phonetic`.

## Cron summary

| Node | Job | Schedule |
|------|-----|----------|
| PHP box (root) | `fail2banUpdate.sh` | daily 05:00 |
| PHP box (nginx) | S3 media backup | daily 05:00 |
| PHP box (nginx) | GoAccess report | daily 01:00 |
| PHP box (nginx) | clear `pub/media/import` | Sunday 08:05 |
| Services nginx | `check_magento_cron.sh` | every 5 min |
| Services nginx | n8n Server Monitor workflow | setting (default every 4 h) |
| sqldb / nosqldb / es | service health check | every 2 min |
