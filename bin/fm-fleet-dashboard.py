#!/usr/bin/env python3
"""Local dashboard transport. Fleet facts remain owned by the snapshot and ledger."""
import argparse
import concurrent.futures
import datetime
import http.server
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
LIMIT = 1024 * 1024


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def command(args, env=None, timeout=15):
    # Kill the owned group on timeout, including snapshot observation children.
    with subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, text=True) as proc:
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise RuntimeError("read timed out")
        if proc.returncode:
            raise RuntimeError((err.strip() or "source command failed")[:300])
        return out


def read_history(home):
    result = {"read_at": stamp(), "enabled": (home / "config/fleet-ledger").exists(),
              "events": [], "notice": "", "truncated": False}
    try:
        with (home / "state/fleet-ledger.jsonl").open("rb") as stream:
            size = stream.seek(0, 2)
            start = max(0, size - LIMIT)
            stream.seek(start)
            if start:
                stream.readline()
            data = stream.read(LIMIT)
        result["truncated"] = bool(start)
        seen, bad = set(), 0
        for line in data.splitlines():
            try:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise ValueError("not an object")
                if event.get("v") != 1:
                    continue
                if event.get("event") not in {"task.merged", "task.status"}:
                    continue
                if event["event"] == "task.status" and event.get("state") != "done":
                    continue
                if (not isinstance(event.get("ts"), (int, float))
                        or not math.isfinite(event["ts"]) or not 0 <= event["ts"] <= 253402300799):
                    raise ValueError("missing event time")
                key = json.dumps(event, sort_keys=True)
                if key not in seen:
                    result["events"].append(event)
                    seen.add(key)
            except (ValueError, TypeError):
                bad += 1
        result["events"] = sorted(result["events"], key=lambda e: e["ts"], reverse=True)[:30]
        result["notice"] = ("Ledger on" if result["enabled"] else "Ledger off; saved history only")
        if start:
            result["notice"] += "; newest 1 MiB only"
        if bad:
            result["notice"] += f"; {bad} incomplete or invalid records skipped"
    except OSError as exc:
        result["notice"] = "Ledger unavailable" if result["enabled"] else "Ledger off; no saved history"
        result["error"] = str(exc)
    return result


def gh_fields(path, query, graphql=None):
    # gh-axi emits TOON scalars. Restrict projections to known simple keys/values.
    args = ["gh-axi", "api", "POST" if graphql else "GET", path, "--hostname", "github.com",
            "--jq", query, "--full"]
    if graphql:
        args += ["--field", "query=" + graphql]
    out = command(args)
    fields = {}
    for line in out.splitlines():
        key, sep, value = line.partition(": ")
        if sep and re.fullmatch(r"[a-z_]+", key):
            fields[key] = value.strip().strip('"')
    return fields


def read_pr(url):
    result = {"url": url, "read_at": stamp(), "ci": "Unavailable", "review": "Unavailable"}
    match = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)", url)
    if not match:
        result["notice"] = "Live checks support github.com PRs only"
        return result
    owner, repo, number = match.groups()
    try:
        # One read-only GraphQL query keeps CI and review attached to the same PR head.
        query = ('query { repository(owner:"' + owner + '",name:"' + repo + '") {'
                 'pullRequest(number:' + number + ') { state reviewDecision headRefOid '
                 'commits(last:1) { nodes { commit { statusCheckRollup { state } } } } } } }')
        fields = gh_fields("/graphql",
                           '{errors:(.errors|length),state:.data.repository.pullRequest.state,'
                           'head:.data.repository.pullRequest.headRefOid,'
                           'review:.data.repository.pullRequest.reviewDecision,'
                           'ci:.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state}', query)
        if (fields.get("errors") != "0" or not {"head", "ci", "review"}.issubset(fields)
                or fields.get("head") in {None, "null", ""}
                or fields.get("state") not in {"OPEN", "CLOSED", "MERGED"}):
            raise RuntimeError("forge response unavailable or unsupported")
        result.update({"state": fields["state"], "head": fields.get("head"),
                       "ci": {"SUCCESS": "Passing", "FAILURE": "Failing", "ERROR": "Error",
                              "PENDING": "Pending", "EXPECTED": "Expected", "null": "No checks reported"}.get(fields.get("ci"), "Unavailable"),
                       "review": {"APPROVED": "Approved", "CHANGES_REQUESTED": "Changes requested",
                                  "REVIEW_REQUIRED": "Review required", "null": "No review decision"}.get(fields.get("review"), "Unavailable"),
                       "notice": "GitHub · current PR head"})
    except (OSError, RuntimeError) as exc:
        result["notice"] = "Forge call failed: " + str(exc)
    result["read_at"] = stamp()
    return result


def pr_urls(snapshot):
    urls = set()
    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in {"pr_url", "url", "pr"} and isinstance(item, str) and "/pull/" in item:
                    urls.add(item)
                elif isinstance(item, (dict, list)):
                    walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    # Current inventory only; no live queries for historical completions.
    walk(snapshot.get("tasks", []))
    for task in snapshot.get("tasks", []):
        for decision in task.get("hints", {}).get("open_decisions", []):
            urls.update(re.findall(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?=[\s)\],;]|$)", decision.get("summary", "")))
    walk([r for r in snapshot.get("backlog", {}).get("records", []) if r.get("state") != "done"])
    for home in snapshot.get("secondmate_current", {}).get("records", []):
        for field in ("active_children", "decisions_open", "holds", "queued"):
            walk(home.get(field, []))
    return sorted(urls)


class Dashboard:
    def __init__(self, home, forge=False, snapshot_file=None):
        self.home, self.forge, self.snapshot_file = home, forge, snapshot_file
        self.lock = threading.Lock()
        self.cached, self.last_read = None, 0

    def read(self):
        with self.lock:
            if self.cached and time.monotonic() - self.last_read < 15:
                return self.cached
            result = {"read_at": stamp(), "snapshot": None, "error": None,
                      "history": read_history(self.home), "forge": {}, "forge_enabled": self.forge}
            try:
                if self.snapshot_file:
                    raw = self.snapshot_file.read_text()
                else:
                    # Scratch never lives in a fleet home, even if TMPDIR was configured there.
                    with tempfile.TemporaryDirectory(prefix="fm-dashboard-", dir="/tmp") as scratch:
                        env = {k: v for k, v in os.environ.items()
                               if not k.startswith(("FM_", "BASH_FUNC_")) and k not in {"BASH_ENV", "ENV"}}
                        env.update(FM_HOME=str(self.home), TMPDIR=scratch)
                        raw = command(["bash", str(HERE / "fm-fleet-snapshot.sh"), "--local-read-only"],
                                      env=env, timeout=60)
                snapshot = json.loads(raw)
                if not isinstance(snapshot, dict) or snapshot.get("schema") != "fm-fleet-snapshot.v1":
                    raise ValueError("unsupported snapshot schema")
                result["snapshot"] = snapshot
                urls = pr_urls(snapshot)
                result["forge_omitted"] = max(0, len(urls) - 12) if self.forge else 0
                if self.forge:
                    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                        for row in pool.map(read_pr, urls[:12]):
                            result["forge"][row["url"]] = row
            except (OSError, ValueError, RuntimeError) as exc:
                result["error"] = "Snapshot unavailable: " + str(exc)
            result["read_at"] = stamp()
            self.cached, self.last_read = result, time.monotonic()
            return result


def serve(dashboard, port):
    token = secrets.token_urlsafe(24)
    page = (HERE / "fm-fleet-dashboard.html").read_bytes()
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log a secret URL or private source contents.

        def do_GET(self):
            authority = f"127.0.0.1:{self.server.server_port}"
            if self.headers.get("Host") != authority or self.headers.get("Origin") not in {None, "http://" + authority}:
                self.send_error(403)
                return
            if self.path == f"/{token}/":
                body, mime = page, "text/html; charset=utf-8"
            elif self.path == f"/{token}/data":
                body, mime = json.dumps(dashboard.read()).encode(), "application/json"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(body)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Fleet dashboard: http://127.0.0.1:{server.server_port}/{token}/", flush=True)
    print("Local and read-only. Keep this URL private. Ctrl-C stops the server.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description="Private, read-only fleet dashboard on 127.0.0.1.",
        epilog="Requires Python 3 and existing snapshot dependencies. No installed packages or external assets. "
        "Refresh is manual, coalesced for 15 seconds. Source observations older than 5 minutes are marked stale. "
        "Remote homes use existing snapshot caches only; no SSH or cache writes. "
        "--forge makes read-only gh-axi calls for up to 12 recorded PRs on github.com. "
        "History reads the newest 1 MiB of this home's optional ledger. "
        "No home, state, backlog, config or forge writes. Stop with Ctrl-C; no daemon or setup changes.")
    parser.add_argument("--home", type=Path, default=Path(os.environ.get("FM_HOME", HERE.parent)), help="operational home (default FM_HOME or code root)")
    parser.add_argument("--port", type=int, default=0, help="loopback port (default: choose a free port)")
    parser.add_argument("--forge", action="store_true", help="read live GitHub CI and review status using gh-axi")
    parser.add_argument("--snapshot", type=Path, help="read a saved snapshot instead of observing live fleet; original timestamps remain visible")
    parser.add_argument("--json", action="store_true", help="print one dashboard data sample and exit")
    args = parser.parse_args()
    if not args.home.is_dir():
        parser.error("home must be an existing directory")
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    dashboard = Dashboard(args.home.resolve(), args.forge, args.snapshot)
    if args.json:
        print(json.dumps(dashboard.read()))
    else:
        serve(dashboard, args.port)


if __name__ == "__main__":
    main()
