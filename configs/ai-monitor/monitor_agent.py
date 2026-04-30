"""CrewAI-based server monitor.

Run via cron as root. Reads /etc/server-monitor/config.yaml, builds the
configured agents, runs them once, appends a single JSON entry to the log,
and exits. Designed to be tolerant of network/API failures - it never
exits non-zero on a Gemini outage; it caches the previous result and
reports a best-effort status.
"""
from __future__ import annotations

# Swap stdlib sqlite3 for pysqlite3-binary BEFORE any crewai/chromadb import
# (RHEL 9 sqlite is 3.34.x; chromadb needs >=3.35). Same shim as tools.py;
# either entry path is safe.
try:
    import pysqlite3  # type: ignore
    import sys as _sys
    _sys.modules["sqlite3"] = pysqlite3
except ImportError:
    pass

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

# tools.py lives next to this file
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tools as t  # noqa: E402

DEFAULT_CONFIG = "/etc/server-monitor/config.yaml"
RISK_LEVELS = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]


class TimeoutError_(Exception):
    pass


def _alarm(seconds: int):
    def _handler(signum, frame):
        raise TimeoutError_(f"run exceeded {seconds}s")
    signal.signal(signal.SIGALRM, _handler)
    signal.alarm(seconds)


def load_config(path: str) -> dict:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
    cfg.setdefault("server_name", socket.gethostname())
    cfg.setdefault("server_type", "magento")
    cfg.setdefault("schedule", "0 */4 * * *")
    cfg.setdefault("alert_threshold", "HIGH")
    cfg.setdefault("model", "gemini/gemini-1.5-flash")
    cfg.setdefault("run_timeout_seconds", 300)
    cfg.setdefault("agents", ["security", "health", "application"])
    cfg.setdefault("log_file", "/var/log/server-monitor.log")
    cfg.setdefault("cache_file", "/var/lib/server-monitor/last-result.json")
    return cfg


def append_log(log_file: str, entry: dict) -> None:
    Path(log_file).parent.mkdir(parents=True, exist_ok=True)
    with open(log_file, "a") as f:
        f.write(json.dumps(entry, default=str) + "\n")


def cache_result(cache_file: str, entry: dict) -> None:
    Path(cache_file).parent.mkdir(parents=True, exist_ok=True)
    with open(cache_file, "w") as f:
        json.dump(entry, f, indent=2, default=str)


def next_run_time(schedule: str) -> str:
    """Best-effort next-run estimate. Falls back to '+4h' if croniter is
    unavailable - it's only ever used for log decoration."""
    try:
        from croniter import croniter
        return croniter(schedule, datetime.now(timezone.utc)).get_next(datetime).isoformat()
    except Exception:
        return (datetime.now(timezone.utc) + timedelta(hours=4)).isoformat()


def parse_risk(text: str) -> str:
    """Extract a risk level from agent free-text output."""
    upper = (text or "").upper()
    for level in reversed(RISK_LEVELS):  # highest wins
        if level in upper:
            return level
    return "LOW"


def risk_at_or_above(level: str, threshold: str) -> bool:
    return RISK_LEVELS.index(level) >= RISK_LEVELS.index(threshold)


def send_email_alert(cfg: dict, entry: dict) -> None:
    if not cfg.get("alert_email"):
        return
    body = json.dumps(entry, indent=2, default=str)
    subj = f"[server-monitor:{entry['risk_level']}] {entry['server_name']}"
    try:
        proc = subprocess.Popen(
            ["mail", "-s", subj, cfg["alert_email"]],
            stdin=subprocess.PIPE, text=True,
        )
        proc.communicate(body, timeout=20)
    except Exception:
        pass  # email is best-effort; the JSON log is the source of truth


def build_agents(cfg: dict):
    """Lazy-import CrewAI so dry-run mode works without it installed."""
    from crewai import Agent, Crew, Process, Task, LLM

    api_key = cfg.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise RuntimeError("gemini_api_key missing in config and GEMINI_API_KEY unset")
    os.environ["GEMINI_API_KEY"] = api_key

    llm = LLM(model=cfg["model"], api_key=api_key, temperature=0.2)

    selected = set(cfg["agents"])
    server_type = cfg["server_type"]
    agents, tasks = [], []

    if "security" in selected:
        sec = Agent(
            role="Linux Security Analyst",
            goal="Detect intrusions, attack attempts, and anomalous binaries on this server.",
            backstory="You triage logs and process state on a production Magento server. Be specific, not generic.",
            tools=t.SECURITY_TOOLS, llm=llm, allow_delegation=False, verbose=False,
        )
        agents.append(sec)
        tasks.append(Task(
            description=(
                "Audit security posture. Use scan_auth_log, scan_web_logs, "
                "recent_executables, check_file_integrity, scan_processes. "
                "Cross-reference findings. End your answer with a single line "
                "'RISK: <LOW|MEDIUM|HIGH|CRITICAL>' followed by 3-8 bullet "
                "findings citing concrete IPs, paths, or counts."
            ),
            expected_output="RISK line + bullet findings.",
            agent=sec,
        ))

    if "health" in selected:
        hlt = Agent(
            role="System Reliability Engineer",
            goal="Keep the server healthy: disk, memory, CPU, DB, backups.",
            backstory="You catch capacity and reliability issues before they page someone.",
            tools=t.HEALTH_TOOLS, llm=llm, allow_delegation=False, verbose=False,
        )
        agents.append(hlt)
        tasks.append(Task(
            description=(
                "Inspect disk, memory, CPU load, DB ping, backup freshness, "
                "and zombie processes. Flag anything above 80% utilization "
                "or stale by >24h. End with 'RISK: <level>' and bullet findings "
                "with the actual numbers."
            ),
            expected_output="RISK line + bullet findings with numbers.",
            agent=hlt,
        ))

    if "application" in selected:
        if server_type in ("magento", "both"):
            app_tools = t.APP_MAGENTO_TOOLS
            stack = "Magento 2"
        else:
            app_tools = t.APP_DRUPAL_TOOLS
            stack = "Drupal"
        app = Agent(
            role=f"{stack} Application Monitor",
            goal=f"Surface application-level errors and stuck jobs on this {stack} install.",
            backstory=f"You know the {stack} log conventions and where corruption hides.",
            tools=app_tools, llm=llm, allow_delegation=False, verbose=False,
        )
        agents.append(app)
        tasks.append(Task(
            description=(
                f"Inspect {stack} application state. Read the application logs "
                "and check cache/cron health. End with 'RISK: <level>' and "
                "concrete bullet findings (file, error type, count)."
            ),
            expected_output="RISK line + bullet findings.",
            agent=app,
        ))

    crew = Crew(agents=agents, tasks=tasks, process=Process.sequential, verbose=False)
    return crew, tasks


def run_dry_run(cfg: dict) -> dict:
    """Show what would be checked without calling the LLM."""
    return {
        "mode": "dry-run",
        "server_name": cfg["server_name"],
        "server_type": cfg["server_type"],
        "agents": cfg["agents"],
        "tools_available": {
            "security": [tool.name for tool in t.SECURITY_TOOLS],
            "health": [tool.name for tool in t.HEALTH_TOOLS],
            "application_magento": [tool.name for tool in t.APP_MAGENTO_TOOLS],
            "application_drupal": [tool.name for tool in t.APP_DRUPAL_TOOLS],
        },
        "next_run": next_run_time(cfg["schedule"]),
    }


def run_health_check(cfg: dict) -> dict:
    """Report when the agent itself last ran."""
    log = cfg["log_file"]
    if not os.path.exists(log):
        return {"status": "never_run", "log": log}
    st = os.stat(log)
    age = (datetime.now() - datetime.fromtimestamp(st.st_mtime)).total_seconds() / 3600
    return {
        "status": "ok" if age < 8 else "stale",
        "log": log,
        "last_run_hours_ago": round(age, 2),
    }


def run_once(cfg: dict) -> dict:
    started = time.time()
    started_iso = datetime.now(timezone.utc).isoformat()
    base = {
        "timestamp": started_iso,
        "server_name": cfg["server_name"],
        "server_type": cfg["server_type"],
        "next_scheduled_run": next_run_time(cfg["schedule"]),
    }

    if not (cfg.get("gemini_api_key") or os.environ.get("GEMINI_API_KEY")):
        return {**base, "status": "disabled", "risk_level": "LOW",
                "findings": ["gemini_api_key not configured"], "duration_seconds": 0}

    try:
        _alarm(int(cfg["run_timeout_seconds"]))
        crew, tasks = build_agents(cfg)
        crew.kickoff()
        signal.alarm(0)

        per_task = []
        worst = "LOW"
        for task in tasks:
            out = str(task.output) if task.output is not None else ""
            level = parse_risk(out)
            if RISK_LEVELS.index(level) > RISK_LEVELS.index(worst):
                worst = level
            per_task.append({
                "agent": task.agent.role,
                "task": task.description.split(".")[0][:120],
                "risk_level": level,
                "findings": out.strip()[:4000],
            })
        entry = {
            **base, "status": "ok", "risk_level": worst,
            "agents": per_task,
            "duration_seconds": round(time.time() - started, 1),
        }
    except TimeoutError_ as e:
        entry = {**base, "status": "timeout", "risk_level": "MEDIUM",
                 "findings": [str(e)], "duration_seconds": round(time.time() - started, 1)}
    except Exception as e:
        entry = {**base, "status": "error", "risk_level": "MEDIUM",
                 "findings": [f"{type(e).__name__}: {e}"],
                 "traceback": traceback.format_exc().splitlines()[-10:],
                 "duration_seconds": round(time.time() - started, 1)}
    finally:
        signal.alarm(0)

    return entry


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--config", default=DEFAULT_CONFIG)
    p.add_argument("--dry-run", action="store_true",
                   help="Show what would be checked without calling Gemini.")
    p.add_argument("--health-check", action="store_true",
                   help="Print last-run age and exit.")
    args = p.parse_args(argv)

    cfg = load_config(args.config)

    if args.health_check:
        print(json.dumps(run_health_check(cfg), indent=2))
        return 0
    if args.dry_run:
        print(json.dumps(run_dry_run(cfg), indent=2))
        return 0

    entry = run_once(cfg)
    append_log(cfg["log_file"], entry)
    cache_result(cfg["cache_file"], entry)

    if cfg.get("alert_threshold", "NONE") != "NONE":
        threshold = cfg["alert_threshold"].upper()
        if threshold in RISK_LEVELS and risk_at_or_above(entry["risk_level"], threshold):
            send_email_alert(cfg, entry)

    return 0  # always 0 - cron should not see this as a failure


if __name__ == "__main__":
    sys.exit(main())
