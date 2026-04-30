"""Local system inspection tools used by the CrewAI monitor agents.

All tools are thin wrappers around shell commands or /proc reads. They never
talk to the network or accept input from the LLM that ends up in a shell -
arguments to subprocess calls are always literal lists.
"""
from __future__ import annotations

# Swap stdlib sqlite3 for pysqlite3-binary BEFORE any crewai/chromadb import.
# AlmaLinux 9 ships sqlite 3.34.x; chromadb (a crewai transitive dep) needs
# >=3.35. pysqlite3-binary bundles a fresh build.
try:
    import pysqlite3  # type: ignore
    import sys as _sys
    _sys.modules["sqlite3"] = pysqlite3
except ImportError:
    pass

import json
import os
import re
import shutil
import socket
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from crewai.tools import tool

AUTH_LOG_CANDIDATES = ["/var/log/secure", "/var/log/auth.log"]
NGINX_ACCESS_GLOB = "/var/log/nginx/access*.log"
NGINX_ERROR_GLOB = "/var/log/nginx/error*.log"
APACHE_ERROR_GLOB = "/var/log/apache2/error*.log"
SYSTEM_BIN_PATHS = ["/usr/bin", "/usr/sbin", "/usr/local/bin", "/usr/local/sbin"]
MAGENTO_ROOT = "/var/www/webroot/ROOT"
MAGENTO_LOG_DIR = f"{MAGENTO_ROOT}/var/log"
MAGENTO_CRITICAL_FILES = [
    f"{MAGENTO_ROOT}/app/etc/env.php",
    f"{MAGENTO_ROOT}/app/etc/config.php",
]


def _run(cmd: list[str], timeout: int = 20) -> str:
    """Run a command, return stdout (and stderr on failure). Never raises."""
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
        return (out.stdout or "") + (out.stderr or "")
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        return f"[command failed: {e}]"


def _tail(path: str, lines: int = 500) -> str:
    if not os.path.exists(path):
        return ""
    return _run(["tail", "-n", str(lines), path])


def _glob_tail(pattern: str, lines: int = 500) -> str:
    from glob import glob
    parts = []
    for p in sorted(glob(pattern))[-3:]:
        parts.append(f"--- {p} ---\n{_tail(p, lines)}")
    return "\n".join(parts)


# --------------------------------------------------------------------------
# Security tools
# --------------------------------------------------------------------------

@tool("scan_auth_log")
def scan_auth_log() -> str:
    """Return a summary of failed logins, accepted root logins, and sudo
    usage from the system auth log over the most recent ~500 lines."""
    for candidate in AUTH_LOG_CANDIDATES:
        if os.path.exists(candidate):
            content = _tail(candidate, 1000)
            failed = re.findall(r"Failed password for (?:invalid user )?(\S+) from (\S+)", content)
            accepted_root = re.findall(r"Accepted \S+ for root from (\S+)", content)
            sudo_calls = re.findall(r"sudo:.*COMMAND=(.+)", content)
            failed_summary: dict[str, int] = {}
            for user, ip in failed:
                key = f"{user}@{ip}"
                failed_summary[key] = failed_summary.get(key, 0) + 1
            top = sorted(failed_summary.items(), key=lambda x: -x[1])[:15]
            return json.dumps({
                "log": candidate,
                "failed_logins_top": top,
                "failed_total": len(failed),
                "accepted_root_from": list(set(accepted_root)),
                "recent_sudo": sudo_calls[-10:],
            })
    return json.dumps({"error": "no auth log found"})


@tool("scan_web_logs")
def scan_web_logs() -> str:
    """Look for common attack patterns in recent nginx/apache logs."""
    content = _glob_tail(NGINX_ACCESS_GLOB, 2000) or _glob_tail(APACHE_ERROR_GLOB, 2000)
    if not content:
        return json.dumps({"error": "no web access logs found"})
    patterns = {
        "sqli": r"(?i)(union\s+select|or\s+1=1|sleep\(|benchmark\()",
        "xss": r"(?i)(<script|onerror=|onload=|javascript:)",
        "lfi": r"(\.\./){2,}|/etc/passwd|/proc/self",
        "rce": r"(?i)(\$\(|`.*`|;\s*(curl|wget|bash|sh)\s)",
        "magento_admin_probe": r"/(downloader|rss/catalog|admin/index|index\.php/admin)",
        "phpmyadmin_probe": r"(?i)/(phpmyadmin|pma|mysql|adminer)",
        "shell_upload": r"\.(php|phtml|asp|jsp)\?.*=",
        "scanner_ua": r"(?i)(nmap|sqlmap|nikto|acunetix|wpscan|masscan|zgrab)",
    }
    findings: dict[str, list[str]] = {}
    for label, pat in patterns.items():
        hits = re.findall(r"^.*" + pat + r".*$", content, re.MULTILINE)
        if hits:
            findings[label] = hits[:5]
    return json.dumps({"hits_by_category": findings, "categories_total": {k: len(v) for k, v in findings.items()}})


@tool("recent_executables")
def recent_executables() -> str:
    """List executables in system bin paths modified in the last 24h."""
    cutoff = datetime.now() - timedelta(hours=24)
    recent = []
    for base in SYSTEM_BIN_PATHS:
        if not os.path.isdir(base):
            continue
        try:
            for entry in os.scandir(base):
                if not entry.is_file(follow_symlinks=False):
                    continue
                st = entry.stat(follow_symlinks=False)
                if datetime.fromtimestamp(st.st_mtime) > cutoff and (st.st_mode & 0o111):
                    recent.append({
                        "path": entry.path,
                        "size": st.st_size,
                        "mtime": datetime.fromtimestamp(st.st_mtime).isoformat(),
                    })
        except PermissionError:
            continue
    return json.dumps({"recent_executables": recent[:50], "count": len(recent)})


@tool("check_file_integrity")
def check_file_integrity() -> str:
    """Hash and stat critical Magento/system files so anomalies are visible
    across runs (compare with prior log entries)."""
    import hashlib
    results = []
    targets = MAGENTO_CRITICAL_FILES + [
        "/etc/passwd", "/etc/shadow", "/etc/sudoers", "/etc/ssh/sshd_config",
        "/etc/nginx/nginx.conf", "/etc/php-fpm.conf",
    ]
    for path in targets:
        if not os.path.exists(path):
            continue
        try:
            st = os.stat(path)
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()
            results.append({
                "path": path, "sha256": digest[:16], "size": st.st_size,
                "mtime": datetime.fromtimestamp(st.st_mtime).isoformat(),
                "mode": oct(st.st_mode & 0o7777),
            })
        except (OSError, PermissionError) as e:
            results.append({"path": path, "error": str(e)})
    return json.dumps(results)


@tool("scan_processes")
def scan_processes() -> str:
    """List long-running processes, listening sockets, and processes whose
    binary path is unusual (a basic rootkit/anomaly heuristic)."""
    ps = _run(["ps", "-eo", "pid,user,etime,rss,cmd", "--sort=-rss"])
    listening = _run(["ss", "-tlnp"])
    suspicious = []
    for line in ps.splitlines()[1:50]:
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        cmd = parts[4]
        if any(s in cmd for s in ["/tmp/", "/dev/shm/", "/var/tmp/"]) and not cmd.startswith("["):
            suspicious.append(line.strip())
    return json.dumps({
        "top_memory_processes": ps.splitlines()[:15],
        "listening_sockets": listening.splitlines()[:25],
        "suspicious_paths": suspicious,
    })


# --------------------------------------------------------------------------
# Health tools
# --------------------------------------------------------------------------

@tool("disk_usage")
def disk_usage() -> str:
    """Disk usage per filesystem and largest directories under /var."""
    df = _run(["df", "-hT", "-x", "tmpfs", "-x", "devtmpfs"])
    largest = _run(["du", "-h", "--max-depth=2", "/var/log", "/var/www"], timeout=60)
    return json.dumps({"df": df.splitlines(), "largest_dirs": largest.splitlines()[:20]})


@tool("memory_usage")
def memory_usage() -> str:
    """Memory + swap usage, plus top RSS consumers."""
    free = _run(["free", "-h"])
    top = _run(["ps", "-eo", "pid,user,rss,cmd", "--sort=-rss"])
    return json.dumps({"free": free.splitlines(), "top_processes": top.splitlines()[:10]})


@tool("cpu_load")
def cpu_load() -> str:
    """Load averages and CPU count for context."""
    load = os.getloadavg()
    cpus = os.cpu_count() or 1
    uptime = _run(["uptime"]).strip()
    return json.dumps({
        "load_1_5_15": load, "cpu_count": cpus,
        "load_per_cpu": [round(l / cpus, 2) for l in load],
        "uptime": uptime,
    })


@tool("database_health")
def database_health() -> str:
    """Probe MariaDB/MySQL on DB_MASTER (Magento env) using credentials from
    the environment. Returns connection status and basic stats."""
    user = os.environ.get("DB_USER", "")
    pw = os.environ.get("DB_PASS", "")
    host = os.environ.get("DB_HOST", "DB_MASTER")
    if not user or not pw:
        return json.dumps({"skipped": "DB_USER/DB_PASS not set in env"})
    ping = _run(["mysqladmin", f"-u{user}", f"-p{pw}", "-h", host, "ping"])
    status = _run(["mysqladmin", f"-u{user}", f"-p{pw}", "-h", host, "extended-status"])
    interesting = [l for l in status.splitlines() if any(k in l for k in [
        "Threads_connected", "Threads_running", "Slow_queries", "Aborted_connects",
        "Innodb_row_lock_waits", "Uptime", "Questions",
    ])]
    return json.dumps({"ping": ping.strip(), "stats": interesting})


@tool("check_backups")
def check_backups() -> str:
    """Look for backup log entries in the last 24h."""
    log = "/var/www/webroot/ROOT/var/log/backups.log"
    if not os.path.exists(log):
        return json.dumps({"missing": log})
    cutoff = datetime.now() - timedelta(hours=24)
    st = os.stat(log)
    return json.dumps({
        "log": log,
        "last_modified": datetime.fromtimestamp(st.st_mtime).isoformat(),
        "fresh_within_24h": datetime.fromtimestamp(st.st_mtime) > cutoff,
        "tail": _tail(log, 30),
    })


@tool("zombie_processes")
def zombie_processes() -> str:
    """Count and list zombie/defunct processes on the host."""
    out = _run(["ps", "-eo", "stat,pid,ppid,cmd"])
    zombies = [l for l in out.splitlines() if l.startswith("Z")]
    return json.dumps({"zombies": zombies, "count": len(zombies)})


# --------------------------------------------------------------------------
# Application tools (Magento focused; Drupal hooks below)
# --------------------------------------------------------------------------

@tool("magento_logs")
def magento_logs() -> str:
    """Tail Magento application logs and surface ERROR/CRITICAL lines."""
    if not os.path.isdir(MAGENTO_LOG_DIR):
        return json.dumps({"missing": MAGENTO_LOG_DIR})
    summary = {}
    for name in ["exception.log", "system.log", "debug.log"]:
        path = f"{MAGENTO_LOG_DIR}/{name}"
        if not os.path.exists(path):
            continue
        content = _tail(path, 500)
        errors = [l for l in content.splitlines() if re.search(r"\b(ERROR|CRITICAL|EMERGENCY|ALERT)\b", l)]
        summary[name] = {"recent_errors": errors[-10:], "count": len(errors)}
    return json.dumps(summary)


@tool("magento_cache_status")
def magento_cache_status() -> str:
    """Run bin/magento cache:status as the nginx user."""
    cmd = ["sudo", "-u", "nginx", "php", f"{MAGENTO_ROOT}/bin/magento", "cache:status"]
    return json.dumps({"output": _run(cmd, timeout=30).splitlines()[:40]})


@tool("magento_cron_recency")
def magento_cron_recency() -> str:
    """Check the most recent successful Magento cron run via the DB."""
    user = os.environ.get("DB_USER", "")
    pw = os.environ.get("DB_PASS", "")
    if not user or not pw:
        return json.dumps({"skipped": "DB credentials missing"})
    q = "SELECT job_code, status, MAX(executed_at) FROM cron_schedule WHERE executed_at IS NOT NULL GROUP BY job_code, status ORDER BY 3 DESC LIMIT 20;"
    out = _run(["mysql", f"-u{user}", f"-p{pw}", "-h", "DB_MASTER", "magento", "-e", q])
    return json.dumps({"recent_jobs": out.splitlines()})


@tool("drupal_watchdog")
def drupal_watchdog() -> str:
    """Drupal: read the watchdog table for recent critical entries.
    Returns a 'skipped' marker on Magento-only servers."""
    drupal_root_candidates = ["/var/www/html", "/var/www/webroot/ROOT"]
    for root in drupal_root_candidates:
        if os.path.exists(f"{root}/core/lib/Drupal.php") or os.path.exists(f"{root}/sites/default/settings.php"):
            out = _run(["sudo", "-u", "nginx", "php", f"{root}/vendor/bin/drush", "watchdog:show", "--severity=Critical", "--count=20"], timeout=30)
            return json.dumps({"drupal_root": root, "watchdog": out.splitlines()})
    return json.dumps({"skipped": "no Drupal install detected"})


# --------------------------------------------------------------------------
# Meta
# --------------------------------------------------------------------------

@tool("server_facts")
def server_facts() -> str:
    """Return hostname, kernel, distro, uptime - cheap context for the LLM."""
    return json.dumps({
        "hostname": socket.gethostname(),
        "uname": _run(["uname", "-a"]).strip(),
        "os_release": _tail("/etc/os-release", 20),
        "uptime": _run(["uptime"]).strip(),
        "ip": _run(["hostname", "-I"]).strip(),
    })


SECURITY_TOOLS = [scan_auth_log, scan_web_logs, recent_executables,
                  check_file_integrity, scan_processes, server_facts]
HEALTH_TOOLS = [disk_usage, memory_usage, cpu_load, database_health,
                check_backups, zombie_processes, server_facts]
APP_MAGENTO_TOOLS = [magento_logs, magento_cache_status, magento_cron_recency, server_facts]
APP_DRUPAL_TOOLS = [drupal_watchdog, server_facts]
