# PHP Hosting Environment for Jelastic / Virtuozzo Application Platform

Two environments, two add-ons. The PHP box is disposable; the services are not.
Site profiles: **Magento 2 / Mage-OS** and **Drupal**.

```
┌─ PHP environment ───────────────┐     ┌─ Services environment ───────────────────────┐
│ AppServer  (cp, docker          │     │ nginx node  (cp)   n8n, cron health check    │
│   jelastic/nginxphp:<tag>)      │────▶│ DB          (sqldb)  MariaDB / MySQL 8       │
│   nginx, php-fpm, local redis   │     │ Redis       (nosqldb)  sessions   (optional) │
│   fail2ban, monit, goaccess     │◀────│ OpenSearch  (es)                  (optional) │
│   add-on: ProxiBlue PHP Box     │ ssh │ NFS         (storage)  media / files         │
└─────────────────────────────────┘     │ add-on: ProxiBlue Services        (optional) │
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
Redeploy keeps the volumes (`/var/www/webroot/ROOT`, `/var/www/webroot/nfs`),
the mount points, and the paths in `/etc/jelastic/redeploy.conf` (`/etc/php.d/`,
`/etc/php-fpm.conf`, `/var/spool/cron/nginx`, `/var/lib/nginx/.ssh/`) and wipes
everything else: `/etc/nginx`, yum packages, root cron, `/etc/hosts`, monit,
fail2ban.

The PHP Box add-on hooks `onAfterRedeployContainer` and re-runs
`scripts/provision-cp.sh`, so the box is fully configured again before the
dialog closes. The Let's Encrypt add-on does the same for its certificate.

## Building a PHP box

**Import** → **URL** → `.../<ref>/manifest.jps`. Fields:

| Field | Meaning |
|-------|---------|
| PHP Version | `jelastic/nginxphp` tag |
| Site profile | `magento` or `drupal`: picks the nginx vhost, fail2ban jails, crons, health probe |
| Services environment | dropdown of your envs; the add-on reads the `sqldb` (and `nosqldb`, `es` if present) node IPs from it via the API. Nothing is installed there. |
| Document root | blank = `ROOT/pub` (magento) / `ROOT/web` (drupal) |
| NFS mounts | shown per profile with prefilled defaults (drupal: `/data` → `ROOT/web/sites/default/files` + the UAT `/backups`, `/data`; magento: `/data` → `ROOT/pub/media`). One per line `<path on storage node> <path on this box>`, `<envName>:/path` for another env's storage. Created via the API, existing mount points untouched |
| Alert / backup email | fail2ban, backup mail |
| Monitor SSH public key | optional, from the Services add-on |
| Config repo ref | pin a commit sha while testing (raw.githubusercontent caches `main` ~5 min) |

Afterwards, on the AppServer (`su -`, password from `phpbox creds`):

1. `phpbox status` - services, versions, DB reachability, mounts, last
   provision result. Mount points are env config and survive redeploys.
2. Deploy code to `/var/www/webroot/ROOT`. DB host in the site config:
   `DB_MASTER` (`/etc/hosts`, re-written on every provision). Redis sessions
   `RD_MASTER`, OpenSearch `ES_MASTER` when those layers exist. Local cache
   Redis: `/tmp/redis.sock`.
3. Bind the domain, install **Let's Encrypt**: **Import** → **URL** →
   `.../addons/letsencrypt-docker.jps`. It is the upstream manifest with
   `targetNodes: nodeGroup: cp` (the Marketplace copy lists stack node types
   only, so it hides itself from a docker-type node), the advanced fields
   declared (external IP on, webroot on, path = document root) and a
   `deployHook` (`scripts/le-deploy-hook.sh`): on a docker node the platform
   does not install the issued cert, so the hook copies it to
   `/var/lib/jelastic/SSL/jelastic.chain|key`, enables `ssl.conf` and
   reloads nginx after every issue/renewal. The provisioner re-enables
   `ssl.conf` after a redeploy. Blank domain = staging cert for the env
   domain; **Configure** with the real domain once DNS points here. `nossl.conf` serves `/.well-known/acme-challenge/`
   from the document root. For a DNS swap-over, issue the cert after DNS
   points at the new box (or copy the old cert into `/var/lib/jelastic/SSL/`
   first and swap `ssl.conf.disabled` → `ssl.conf`).

Existing PHP env: **Import** → **URL** → `.../addons/phpbox-addon.jps`, pick
the env + `cp` layer, same fields. Test on a **clone** first - the
provisioner rewrites `/etc/nginx/nginx.conf`, `/etc/php.d/*`, fail2ban and
monit, and generates **new root/nginx system passwords** (it never touches
`conf.d/SITES_ENABLED/`, `conf.d/CORS/`, `ssl.conf` or `.htpasswd` once they
exist).

### Updating PHP

1. PHP env → AppServer layer → **Redeploy Containers** → choose tag → confirm.
2. Wait for the add-on's `onAfterRedeployContainer` to finish
   (`/var/log/phpbox-provision.log`, last line `... provisioned OK`).
3. `php -v`, `curl -I https://domain/`, monit on `:2812`.

Nothing else changes: IP, certificate, crontab, code, mounts. Proven
2026-10-23 on a Drupal box (`jelastic/nginxphp:1.30.6-php-8.4.27`): the
hook fired, services/TLS/mounts all back without manual steps. If the hook
ever does not fire, press **Re-apply configuration** or run
`phpbox reapply`.

`phpbox reapply <sha>` pins that sha as `REPO_REF` for later redeploys;
pin a recent one so the redeploy run includes all current logic.

`/etc/php.d/` survives the redeploy, which is why the provisioner regenerates
it and drops any `extension=` line whose `.so` does not exist in the new
image (imap gone in 8.4, opcache built in from 8.5).

Jelastic publishes PHP patch images a few weeks after php.net. The
`docker/nginxphp/` image + `.github/workflows/nginxphp-image.yml` rebuild PHP
from source on the newest Jelastic base and publish
`ghcr.io/proxiblue/nginxphp:<tag>`; add ghcr as a custom registry in the
Redeploy dialog to use it. The ghcr path is not yet proven on a real redeploy
(the Docker Hub tag path is).

Image facts that shaped the provisioner (plain `docker` node type, not the
`nginxphp-dockerized` stack): no redis server, `passwd`, `iptables`, `jem`
or `mailx` in the image; `REDIS_ENABLED` is ignored; `stub_status.conf`
listens on `127.0.0.1:80`, so loopback curl tests hit it, not the site.

## Services add-on (optional)

**Import** → **URL** → `.../addons/services-addon.jps`, pick the services env
+ its nginx (`cp`) layer. Installs n8n + the Server Monitor workflow on that
node, which snapshots the local DB/Redis/OpenSearch over the internal network
and the PHP box over SSH. Safe on a live env: data nodes are **not touched**
unless *Harden data nodes* is ticked (the DB restarts once when the my.cnf
block is appended).

| Field | Meaning |
|-------|---------|
| PHP box environment | dropdown; the add-on resolves its `cp` node IP. Blank until it exists, then **Configure**. |
| DB user / password | only for the Magento `cron_schedule` health check. Blank = no check (Drupal). |
| Harden data nodes | my.cnf hardening + restart, Redis/OpenSearch config, health-check crons every 2 min |

Buttons: **Configure** (edit settings, re-apply to the nginx node), **Add
Redis / OpenSearch nodes** (opt-in checkboxes), **Harden data nodes**, **Show
monitor SSH key** (paste into the PHP box add-on's **Authorize monitor
key**), **Update n8n**.

## PHP Box: terminal and buttons

`/usr/local/bin/phpbox` on the AppServer (root):

| Command | Does |
|---------|------|
| `phpbox status` | services, versions, redis ping, DB tcp check, mounts, fail2ban jails, last provision result |
| `phpbox creds` | system / stats / monit passwords |
| `phpbox env` | `/etc/phpbox.env` + `*_MASTER` hosts entries |
| `phpbox reapply [ref]` | re-run the provisioner (from a git ref if given) |
| `phpbox fail2ban-update` | refresh filters/jails |
| `phpbox authorize-key 'ssh-ed25519 ...'` | allow the services monitor in as `nginx` |
| `phpbox log [n]` | provision log tail |

Add-on buttons (same actions, plus the ones that need the platform API):

| Button | Does |
|--------|------|
| Re-apply configuration | Re-runs `provision-cp.sh` (re-resolves the services IPs first) |
| Apply mounts | Creates missing NFS mount points from the MOUNTS setting |
| Update fail2ban filters | Pulls filters/jails for the profile from the repo, restarts fail2ban |
| Authorize monitor key | Adds a public key to `nginx`'s `authorized_keys` |
| Show services IPs | What the dropdown currently resolves to |
| Show credentials | `/root/phpbox-credentials.txt` (system, stats, monit passwords) + `/etc/phpbox.env` |

## What lives where

**PHP box** - everything that must see the local kernel, sockets or logs:
nginx + php-fpm (`configs/nginx`, `configs/php`), local Redis on
`/tmp/redis.sock`, fail2ban (`nginx-badurls` always; magento:
`nginx-search`, `nginx-magento-admin`; drupal: `nginx-drupal-login`; refreshed
daily), monit (nginx, php-fpm, redis; port 2812), logrotate, GoAccess daily
report at `/site_report` (basic auth `stats`), Node.js 22, AWS CLI v2,
`n8n-server-snapshot.sh` (read-only collector the services node calls over
SSH as `nginx` via a one-line sudoers rule). Magento only: S3 media backup
cron, weekly `pub/media/import` purge.

**Services nginx node** - n8n (`configs/n8n/`, SQLite, nginx-proxied on the
chosen port behind an IP allowlist), `n8n-services-snapshot.sh`,
`check_magento_cron.sh` every 5 min when DB creds given, config in
`/etc/magento-monitor.env`.

**Data nodes** (only after *Harden data nodes*) - healthcheck cron every 2
min, restart after 3 failures (`configs/healthchecks/`), logrotate, hardening
(`skip-symbolic-links`, `local-infile=0`, phpMyAdmin denied; OpenSearch
security plugin off, single node, `analysis-icu` + `analysis-phonetic`).

Persisted on the PHP box across redeploys (added to `redeploy.conf` by the
provisioner): `/etc/phpbox.env`, `/root/phpbox-credentials.txt`,
`/root/.ssh/`, `/etc/nginx/.htpasswd`, `/etc/nginx/conf.d/SITES_ENABLED/`,
`/etc/nginx/conf.d/CORS/`, `/var/spool/cron/root`, `/var/lib/redis/`.

## Security notes

- PHP: `expose_php=Off`, `allow_url_include=Off`, `open_basedir` (FPM pool only, CLI/drush unrestricted) limited to
  `/var/www/webroot`, `/tmp`, the composer cache and the PHP binary path,
  `disable_functions=passthru` (`proc_open`/`popen` stay: Composer needs
  them), secure session cookies, `request_terminate_timeout=600s`, slowlog
  at 30s.
- nginx (magento): rate limits on admin (30r/s), customer login (2r/s),
  REST/GraphQL (10r/s); PHP execution only for `index.php`, `get.php`,
  `static.php`, `health_check.php`, error handlers; dotfiles and `.php` under
  `media/` denied.
- nginx (drupal): `/user/login|password|register` at 2r/s; `.php` under
  `sites/*/files`, `vendor/`, private dirs and dotfiles denied; `update.php`
  allowed (Drupal's own access check applies).
- Both: 50 connections per IP, security headers, php-fpm status/ping
  localhost only, static assets immutable for a year.
- MariaDB 12.x needs `patches/composer/allow-mariadb-12.patch` in the Magento
  project (adds `^12\.` to the SqlVersionProvider DI config).

## Verification after provisioning

PHP box:

```bash
tail -3 /var/log/phpbox-provision.log           # last line: "... provisioned OK"
cat /etc/phpbox.env; grep MASTER /etc/hosts
php -i | grep -E 'disable_functions|open_basedir'
php -r 'echo 1;' 2>&1 | head -1                   # no startup warnings
systemctl is-active nginx php-fpm redis monit fail2ban
fail2ban-client status
sed -n '/CUSTOM/,/SYSTEM/p' /etc/jelastic/redeploy.conf
```

Services nginx node:

```bash
tail -3 /var/log/services-provision.log
systemctl is-active n8n
sudo -u n8n ssh -i /var/lib/n8n/.ssh/id_ed25519 -o BatchMode=yes nginx@PHPBOX true && echo ssh-ok
sudo /usr/local/bin/n8n-server-snapshot.sh | head -40
```

## Cron summary

| Node | Job | Schedule |
|------|-----|----------|
| PHP box (root) | `fail2banUpdate.sh` | daily 05:00 |
| PHP box (nginx) | GoAccess report | daily 01:00 |
| PHP box (nginx, magento) | S3 media backup | daily 05:00 |
| PHP box (nginx, magento) | clear `pub/media/import` | Sunday 08:05 |
| Services nginx | `check_magento_cron.sh` (if DB creds) | every 5 min |
| Services nginx | n8n Server Monitor workflow | setting (default every 4 h) |
| sqldb / nosqldb / es (if hardened) | service health check | every 2 min |
