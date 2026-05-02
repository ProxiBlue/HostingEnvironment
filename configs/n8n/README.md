# n8n (self-hosted)

Replaces the previous CrewAI-based AI monitor. n8n runs as an unprivileged
systemd service on the AppServer node, persists to SQLite, and is exposed
through nginx on a separate port behind an IP allowlist.

A starter `Server Monitor` workflow ports the old security/health/Magento
checks: cron trigger -> shell snapshot -> Gemini (HTTP node) -> alert email
on `RISK >= HIGH`.

## Layout

| Path | What |
|------|------|
| `/usr/bin/n8n`                          | npm-installed binary (`npm install -g n8n`) |
| `/etc/systemd/system/n8n.service`       | systemd unit (User=n8n, hardened) |
| `/etc/n8n/n8n.env`                      | env file - basic config + `GEMINI_API_KEY`, `N8N_MONITOR_SCHEDULE`, `ALERT_EMAIL`, `SERVER_HOSTNAME` |
| `/var/lib/n8n/`                         | data dir (owner: `n8n`); `database.sqlite` lives here |
| `/var/lib/n8n/workflows-pending/`       | shipped workflow JSON for "Import from File" if auto-import didn't catch |
| `/var/log/n8n.log`                      | rotating stdout/stderr |
| `/etc/nginx/conf.d/n8n.conf`            | reverse-proxy vhost on the configured port + IP allowlist |
| `/usr/local/bin/n8n-server-snapshot.sh` | root-owned data collector invoked by the workflow via NOPASSWD sudo |
| `/etc/sudoers.d/n8n`                    | grants `n8n` user `NOPASSWD` on the snapshot script (and nothing else) |

## Install

### Provisioning (Jelastic build)

`manifest.jps` calls `setupN8N` automatically. The Gemini key, schedule, port,
and IP allowlist come from the install dialog.

### Existing server (manual)

```bash
sudo bash -c 'export N8N_DOMAIN="n8n.<env>.example.com"; \
  export N8N_PORT=5679; \
  export N8N_ALLOWED_IPS="203.0.113.4/32, 198.51.100.0/24"; \
  export GEMINI_API_KEY="..."; \
  export MONITOR_SCHEDULE="0 */4 * * *"; \
  export ALERT_EMAIL="ops@example.com"; \
  curl -fsSL https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/n8n/install_n8n.sh | bash'
```

### Update n8n itself

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/n8n/update_n8n.sh)"
```

`update_n8n.sh` only refreshes the npm package and restarts the service. It
does **not** touch the env file, sqlite db, or workflow JSON. Re-run
`install_n8n.sh` if you also need the snapshot script, sudoers fragment, or
nginx vhost regenerated.

## First login

1. Hit `http://n8n.<your-domain>:<port>/` from an allowlisted source IP.
2. Create the owner account when prompted (email + password). This is n8n's
   built-in user management - the IP allowlist + this account are the two
   things gating access.
3. If the auto-import succeeded, the `Server Monitor` workflow is already
   visible. Otherwise: **Workflows -> Import from File ->**
   `/var/lib/n8n/workflows-pending/server-monitor.json`.
4. Review and **Activate** the workflow.

## Configure / re-tune

Edit `/etc/n8n/n8n.env` for shared values, then `systemctl restart n8n`:

| Key | Effect |
|-----|--------|
| `GEMINI_API_KEY`         | empty -> the HTTP node's `?key=` is empty and Gemini returns a 400; the IF node won't trip but no useful analysis runs |
| `N8N_MONITOR_SCHEDULE`   | cron expression read by the workflow's Schedule trigger via `{{ $env.N8N_MONITOR_SCHEDULE }}` |
| `ALERT_EMAIL`            | recipient for `Send Alert`; falls back to `root` if unset |
| `SERVER_HOSTNAME`        | shown in alert subjects and the Gemini prompt |

The IP allowlist is **not** in `n8n.env` - edit `/etc/nginx/conf.d/n8n.conf`
and `nginx -s reload` to change it. Pattern is plain nginx
`allow <cidr>; ... deny all;` lines.

## SSL

The initial install serves HTTP. The vhost ships with `server_name _;`
(catch-all) so the LE addon's vhost scan doesn't trip on a subdomain
without DNS. To put TLS on `n8n.<domain>`:

1. Create a DNS A record for `n8n.<domain>` pointing at the env IP.
2. Add `n8n.<domain>` to the Jelastic Let's Encrypt addon's `customDomains`
   list and re-run the addon.
3. Edit `/etc/nginx/conf.d/n8n.conf`: change `server_name _;` to
   `server_name n8n.<domain>;`, change `listen <port>;` to
   `listen <port> ssl;`, and add the cert paths LE drops.
4. Flip `N8N_PROTOCOL`/`WEBHOOK_URL`/`N8N_EDITOR_BASE_URL` in `n8n.env`
   to `https`, then `systemctl restart n8n nginx`.

## How the `Server Monitor` workflow works

1. **Schedule** trigger fires on `N8N_MONITOR_SCHEDULE` (default every 4h).
2. **Gather Snapshot** runs `sudo /usr/local/bin/n8n-server-snapshot.sh`. The
   script collects disk/memory/process info, recent failed logins,
   nginx 4xx/5xx, CrowdSec decisions, fail2ban status, Magento exception +
   system logs, cache status, MariaDB ping, Redis ping. Every command has a
   10s timeout and exits 0; the helper never blocks the workflow.
3. **Build Prompt** wraps the snapshot in a fixed-format SRE prompt asking
   for `RISK: <LEVEL>` + `SUMMARY:` + `FINDINGS:` bullets.
4. **Call Gemini** POSTs to `gemini-1.5-flash:generateContent` with the
   API key from env. `neverError: true` so a Gemini 4xx/5xx still flows
   through (you'll see it as `risk_level: UNKNOWN`).
5. **Parse Risk** regex-extracts the level, scores it 0-4, base64-encodes
   the body for safe shell handoff.
6. **Risk >= HIGH?** branches on `risk_score >= 3`.
7. **Send Alert** pipes the base64 body through `mail -s '<subject>' --
   <recipient>` on the HIGH path. `mail` is provided by `s-nail`
   (already installed on the AppServer node).

## Customise / add tools

The snapshot helper is the source of truth for what data the LLM sees - tweak
`/usr/local/bin/n8n-server-snapshot.sh` (or commit to
`configs/n8n/n8n-server-snapshot.sh` and re-run `install_n8n.sh`) to add or
remove sections.

For new workflows, build them in the UI, **export to JSON**, and commit
under `configs/n8n/workflows/` so they ship with the next provision.

## Hardening notes

- n8n runs as the unprivileged `n8n` system user. The systemd unit sets
  `ProtectSystem=full`, `ProtectHome=read-only`, `PrivateTmp=true`,
  `NoNewPrivileges=true`, and `ReadWritePaths` only `/var/lib/n8n` and
  `/var/log/n8n.log`.
- The only privilege n8n has is `NOPASSWD` on the **single** snapshot script
  (see `/etc/sudoers.d/n8n`). Editing the workflow to call other commands
  runs them as `n8n` user, not root.
- Secrets (Gemini key, future SMTP creds) live in `/etc/n8n/n8n.env`,
  mode `0640`, group `n8n`.
- The n8n internal port (5678) only binds to 127.0.0.1; the only public
  surface is the nginx vhost on the configured external port.

## Troubleshoot

| Symptom | Check |
|---------|-------|
| UI 502 Bad Gateway | `systemctl status n8n` and `tail /var/log/n8n.log`. Most often: `npm install -g n8n` finished but env file points at the wrong path. |
| UI returns 403/empty | Source IP isn't in `/etc/nginx/conf.d/n8n.conf` allowlist, or `N8N_ALLOWED_IPS` was blank at install time. |
| Workflow doesn't appear after install | `ls /var/lib/n8n/workflows-pending/` - if `server-monitor.json` is there, import via the UI (auto-import fails until the owner account exists). |
| `Gather Snapshot` fails with "sudo: a password is required" | `/etc/sudoers.d/n8n` missing or wrong perms (`0440`, root-owned). Re-run `install_n8n.sh`. |
| `Send Alert` succeeds but no email | `mail` is configured; check `/var/log/maillog`. The `s-nail` package provides `/usr/bin/mail`. |
| Gemini 429 / quota | Lower the schedule (`0 */6 * * *` or `0 2 * * *`), or switch the model in the **Call Gemini** node URL to `gemini-2.0-flash-exp`. |
| `risk_level: UNKNOWN` every run | Gemini didn't emit `RISK: <level>` - usually means the API key is missing/invalid. Check the **Call Gemini** node's last execution output for the actual response. |
