# AI Server Monitor

Self-contained, cron-driven monitoring agent for the Magento (or Drupal) hosting environment. Runs **locally as root**, calls **Google Gemini** outbound-only, and writes structured JSON to `/var/log/server-monitor.log`. No open ports, no daemon, no inbound access.

## What it monitors

Three CrewAI agents run sequentially on each cron tick:

| Agent | Reads | Reports |
|-------|-------|---------|
| **Security** | `/var/log/secure`, nginx access logs, recent executables under `/usr/{bin,sbin,local/bin}`, hashes of `app/etc/env.php` etc., `ps`/`ss` output | failed-login top talkers, attack patterns (SQLi/XSS/LFI/RCE/scanners), changed binaries, suspicious processes |
| **Health** | `df`, `free`, `/proc`, `mysqladmin ping`, backup log mtime, zombie counts | utilization, capacity headroom, DB reachability, stale backups |
| **Application** (Magento) | `var/log/exception.log`, `system.log`, `bin/magento cache:status`, `cron_schedule` table | recent ERROR/CRITICAL lines, cache backend status, cron recency |
| **Application** (Drupal) | `drush watchdog:show`, settings.php detection | recent critical watchdog entries |

Each agent ends its output with a line `RISK: LOW|MEDIUM|HIGH|CRITICAL`. The worst risk across agents becomes the entry's overall `risk_level`.

## Install

### On a new server (auto)

The Jelastic `manifest.jps` calls `setupAIMonitor` during install. The `GEMINI_API_KEY` you supply at provision time is baked into `/etc/server-monitor/config.yaml`. Leave it blank to install in disabled mode and set the key later.

### On an existing server (manual)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/ai-monitor/install_monitor.sh)"
# then edit the key in
sudo vi /etc/server-monitor/config.yaml
```

The installer:
1. Installs `python3`, `pip`, `mailx` (apt or dnf).
2. Creates `/opt/server-monitor/venv` with `crewai`, `litellm`, `pyyaml`, `croniter`.
3. Drops agent code in `/opt/server-monitor/`.
4. Writes `/etc/server-monitor/config.yaml` (preserves an existing one).
5. Drops `/etc/cron.d/server-monitor` with the configured schedule.
6. Runs `--dry-run` as a smoke test.

## Update

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ProxiBlue/HostingEnvironment/main/configs/ai-monitor/update_monitor.sh)"
```

Refreshes agent code and `pip` deps. **Does not** touch your `config.yaml`.

## View results

```bash
# pretty-print the most recent run
sudo tail -1 /var/log/server-monitor.log | jq

# all HIGH/CRITICAL findings in the last week
sudo grep -E '"risk_level":\s*"(HIGH|CRITICAL)"' /var/log/server-monitor.log | jq

# how long since the agent last ran
sudo /opt/server-monitor/venv/bin/python /opt/server-monitor/monitor_agent.py --health-check
```

A single log entry looks like:

```json
{
  "timestamp": "2026-04-30T14:00:01+00:00",
  "server_name": "node12345.jelastic",
  "server_type": "magento",
  "next_scheduled_run": "2026-04-30T18:00:00+00:00",
  "status": "ok",
  "risk_level": "MEDIUM",
  "agents": [
    {"agent": "Linux Security Analyst", "task": "Audit security posture", "risk_level": "MEDIUM", "findings": "RISK: MEDIUM\n- 412 failed sshd attempts from 45.155.205.x\n- ..."},
    {"agent": "System Reliability Engineer", "task": "Inspect disk, memory, CPU load", "risk_level": "LOW", "findings": "RISK: LOW\n- /var at 62% (124G free)\n- ..."},
    {"agent": "Magento 2 Application Monitor", "task": "Inspect Magento application state", "risk_level": "MEDIUM", "findings": "RISK: MEDIUM\n- 18 ERROR lines in exception.log re: Redis timeout\n- ..."}
  ],
  "duration_seconds": 47.2
}
```

## Configure

Edit `/etc/server-monitor/config.yaml`. Re-running `install_monitor.sh` or `update_monitor.sh` regenerates `/etc/cron.d/server-monitor` from the `schedule:` field.

| Key | Effect |
|-----|--------|
| `gemini_api_key` | empty -> agent runs in disabled mode and only logs `"status": "disabled"` |
| `server_type` | `magento` / `drupal` / `both` - selects the Application agent's tool set |
| `schedule` | cron expression; default `0 */4 * * *` (every 4h) |
| `agents` | list - drop `security` / `health` / `application` to skip |
| `alert_threshold` | `LOW`/`MEDIUM`/`HIGH`/`CRITICAL`/`NONE` - email alerts at or above |
| `alert_email` | recipient; falls back silently if `mail` is unavailable |
| `model` | LiteLLM model id; default `gemini/gemini-1.5-flash` (free tier) |
| `run_timeout_seconds` | hard wallclock cap per cron tick (default 300) |

## Customize tasks / add tools

The agent prompts are hardcoded in `/opt/server-monitor/monitor_agent.py` (function `build_agents`). To tighten or add to them:

1. Edit `monitor_agent.py` and/or `tools.py` in this repo.
2. Commit + push to the GitHub branch the installer pulls from.
3. Run `update_monitor.sh` on each server.

New inspection tools are just functions decorated with `@tool("name")` in `tools.py` - add them to one of the `*_TOOLS` lists at the bottom of the file and they become available to the matching agent.

## Troubleshoot

| Symptom | Check |
|---------|-------|
| No log entries appearing | `cat /var/log/server-monitor-cron.log`; verify `/etc/cron.d/server-monitor` exists; confirm `crond`/`cron` is running |
| `"status": "disabled"` every run | `gemini_api_key` blank in `/etc/server-monitor/config.yaml` |
| `"status": "error"` with `RuntimeError` | manually run `sudo /opt/server-monitor/venv/bin/python /opt/server-monitor/monitor_agent.py` and read the traceback |
| Gemini quota / 429s | switch `model:` to `gemini/gemini-2.0-flash-exp` or back off `schedule:` to every 6h |
| Database checks always skipped | `DB_USER`/`DB_PASS` need to be in root's environment; the manifest exports them via `/etc/environment` |
| Drupal agent says `"skipped"` on a Magento server | expected - set `server_type: magento` in config |

## Security notes

- The agent reads logs and runs `ps`/`ss`/`mysqladmin`. It does not execute LLM-generated code; tools are a fixed Python whitelist.
- Subprocess calls use argument lists, never shell strings.
- Output to Gemini is log/process snippets - if those contain secrets you don't want sent outbound, redact in the corresponding tool before returning.
- The agent has **no listening port** and is reachable only via cron + outbound HTTPS to `generativelanguage.googleapis.com`.
