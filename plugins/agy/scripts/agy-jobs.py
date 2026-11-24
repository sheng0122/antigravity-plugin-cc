"""Background jobs for agy-run.sh: start, watch, status, stop, result.

A job is one detached `agy -p ... --output-format stream-json` process whose
events land in <jobs_dir>/<id>/events.ndjson. There is no fixed time limit;
`watch` follows progress and flags a stall when nothing (the job's own events
or, for swarms, any member's conversation files) has changed for a while.

Usage (called by agy-run.sh):
  agy-jobs.py start  <jobs_dir> <kind> <label> <argv...>
  agy-jobs.py watch  <jobs_dir> <id> [--interval 20s] [--stall 15m] [--heartbeat 5m] [--stop-on-stall]
  agy-jobs.py status <jobs_dir> [<id>]
  agy-jobs.py stop   <jobs_dir> <id>
  agy-jobs.py result <jobs_dir> <id>
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

AGY_HOME = os.environ.get("AGY_HOME") or os.path.expanduser("~/.gemini/antigravity-cli")
KEEP_DAYS = 14


def die(msg, code=64):
    print("error: " + msg, file=sys.stderr)
    sys.exit(code)


def parse_duration(text):
    """Go-style durations ("90s", "15m", "1h30m"); "0" means none."""
    if text == "0":
        return 0.0
    parts = re.findall(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)", text)
    if not parts or "".join(n + u for n, u in parts) != text:
        die("invalid duration '%s' (use e.g. 30s, 15m, 1h)" % text)
    unit = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
    return sum(float(n) * unit[u] for n, u in parts)


def fmt_age(seconds):
    seconds = int(max(seconds, 0))
    h, rest = divmod(seconds, 3600)
    m, s = divmod(rest, 60)
    if h:
        return "%dh%02dm" % (h, m)
    if m:
        return "%dm%02ds" % (m, s)
    return "%ds" % s


def job_dir(jobs_dir, job_id):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", job_id or ""):
        die("invalid job id '%s'" % job_id)
    path = os.path.join(jobs_dir, job_id)
    if not os.path.isfile(os.path.join(path, "meta.json")):
        die("no such job '%s' (list jobs with /agy:status)" % job_id, 1)
    return path


def load_meta(path):
    with open(os.path.join(path, "meta.json"), encoding="utf-8") as f:
        return json.load(f)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A finished child of a still-running parent stays a zombie; treat as gone.
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return bool(out) and not out.startswith("Z")
    except Exception:
        return True


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def read_events(path):
    events = []
    try:
        with open(os.path.join(path, "events.ndjson"), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except ValueError:
                    pass  # a line still being written
    except OSError:
        pass
    return events


def short(text, limit=100):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def describe_step(step):
    info = step.get("tool_info") or {}
    name = step.get("tool_name") or info.get("name")
    params = info.get("parameters") or {}
    if name == "swarm":
        action = params.get("action", "")
        if action == "add":
            return "swarm: added member %s" % params.get("name", "?")
        return "swarm: %s %s" % (action, short(params.get("title") or params.get("name") or "", 60))
    if name == "post_message":
        return "posted: " + short(params.get("text", ""), 80)
    if name:
        detail = (params.get("CommandLine") or params.get("Path") or params.get("Url")
                  or params.get("query") or params.get("Query") or "")
        return "%s %s" % (name, short(detail, 80))
    return None


def swarm_info(conversation_id):
    """Members, board posts and newest activity of a swarm led by this conversation."""
    base = os.path.join(AGY_HOME, "brain", conversation_id, ".system_generated", "swarm")
    members_file = os.path.join(base, "members.json")
    if not os.path.isfile(members_file):
        return None
    try:
        with open(members_file, encoding="utf-8") as f:
            members = json.load(f).get("members", {})
    except (OSError, ValueError):
        members = {}
    posts = []
    try:
        with open(os.path.join(base, "board.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    posts.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    activity = max(mtime(members_file), mtime(os.path.join(base, "board.jsonl")))
    for m in members.values():
        cid = m.get("conversation_id")
        if cid:
            activity = max(activity,
                           mtime(os.path.join(AGY_HOME, "conversations", cid + ".db")),
                           mtime(os.path.join(AGY_HOME, "brain", cid, ".system_generated",
                                              "logs", "transcript.jsonl")))
    workers = sorted(n for n, m in members.items() if m.get("role") != "coordinator")
    return {"workers": workers, "posts": posts, "activity": activity}


def summarize(path):
    meta = load_meta(path)
    events = read_events(path)
    now = time.time()
    cid, steps, last_desc, text, result = None, 0, None, "", None
    for e in events:
        kind = e.get("event")
        if kind == "init":
            cid = e.get("conversation_id") or cid
        elif kind == "step_update":
            s = e.get("step_update") or {}
            cid = s.get("conversation_id") or cid
            if s.get("state") == "DONE":
                steps += 1
            desc = describe_step(s)
            if desc:
                last_desc = desc
            if s.get("step_type") == "agent_response" and s.get("text_delta"):
                text = (text + s["text_delta"])[-400:]
        elif kind == "result":
            result = e.get("result") or {}
            cid = result.get("conversation_id") or cid
    activity = max(mtime(os.path.join(path, "events.ndjson")), meta.get("started", 0))
    swarm = swarm_info(cid) if cid else None
    if swarm:
        activity = max(activity, swarm["activity"])
    running = result is None and alive(meta["pid"])
    if result is not None:
        status = result.get("status")
        state = {"SUCCESS": "done", "INTERRUPTED": "stopped", "CANCELED": "stopped"}.get(status, "failed")
    elif running:
        state = "running"
    else:
        state = "died"
    return {
        "id": meta["id"], "kind": meta.get("kind", "task"), "label": meta.get("label", ""),
        "state": state, "elapsed": (result and result.get("duration_seconds")) or (now - meta["started"]),
        "idle": now - activity, "steps": steps, "last": last_desc, "text": text.strip(),
        "conversation_id": cid, "result": result, "swarm": swarm, "path": path,
    }


def progress_line(s):
    kind = "swarm " if s["kind"] == "swarm" else ""
    bits = ["[%s] %s%s %s" % (s["id"], kind, s["state"], fmt_age(s["elapsed"])), "%d steps" % s["steps"]]
    if s["swarm"]:
        bits.append("%d members, %d board posts" % (len(s["swarm"]["workers"]), len(s["swarm"]["posts"])))
    if s["swarm"] and s["swarm"]["posts"]:
        p = s["swarm"]["posts"][-1]
        bits.append("latest post %s: %s" % (p.get("agent", "?"), short(p.get("text", ""), 80)))
    elif s["last"]:
        bits.append("latest: " + s["last"])
    elif s["text"]:
        bits.append("writing: " + short(s["text"][-120:], 80))
    if s["state"] == "running":
        bits.append("idle " + fmt_age(s["idle"]))
    return " | ".join(bits)


def print_final(s):
    r = s["result"]
    if r is None:
        print("[wrapper] job %s %s without a result." % (s["id"], s["state"]), file=sys.stderr)
        try:
            with open(os.path.join(s["path"], "stderr.log"), encoding="utf-8", errors="replace") as f:
                tail = f.read()[-1500:].strip()
            if tail:
                print("[wrapper] agy stderr (tail):\n" + tail, file=sys.stderr)
        except OSError:
            pass
        return 1
    sys.stdout.write(r.get("response", ""))
    if not r.get("response", "").endswith("\n"):
        print()
    denied = r.get("denied_actions") or []
    if denied:
        names = ", ".join("%s(%s)" % (d.get("action", "?"), d.get("display_name", "?")) for d in denied)
        print("[wrapper] WARNING: %d action(s) were blocked and skipped: %s" % (len(denied), names), file=sys.stderr)
    if s["conversation_id"]:
        print("[wrapper] conversation: %s (follow up with --resume %s)"
              % (s["conversation_id"], s["conversation_id"]), file=sys.stderr)
    usage = r.get("usage") or {}
    print("[wrapper] job %s finished: %s in %s, %s tokens"
          % (s["id"], r.get("status"), fmt_age(r.get("duration_seconds") or s["elapsed"]),
             usage.get("total_tokens", "?")), file=sys.stderr)
    if r.get("status") != "SUCCESS":
        print("[wrapper] error: %s" % r.get("error", ""), file=sys.stderr)
        return 1
    return 0


def prune(jobs_dir):
    cutoff = time.time() - KEEP_DAYS * 86400
    for name in os.listdir(jobs_dir):
        path = os.path.join(jobs_dir, name)
        try:
            meta = load_meta(path)
        except (OSError, ValueError):
            continue
        if meta.get("started", 0) < cutoff and not alive(meta.get("pid", -1)):
            shutil.rmtree(path, ignore_errors=True)


def cmd_start(jobs_dir, kind, label, argv):
    os.makedirs(jobs_dir, exist_ok=True)
    prune(jobs_dir)
    job_id = time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(2).hex()
    path = os.path.join(jobs_dir, job_id)
    os.makedirs(path)
    with open(os.path.join(path, "events.ndjson"), "wb") as out, \
            open(os.path.join(path, "stderr.log"), "wb") as err:
        # New session: the job survives the caller's shell and its process-group kills.
        proc = subprocess.Popen(argv + ["--output-format", "stream-json"], stdin=subprocess.DEVNULL,
                                stdout=out, stderr=err, start_new_session=True)
    meta = {"id": job_id, "pid": proc.pid, "started": time.time(), "cwd": os.getcwd(),
            "kind": kind, "label": label}
    with open(os.path.join(path, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    print(job_id)


def cmd_watch(jobs_dir, job_id, opts):
    path = job_dir(jobs_dir, job_id)
    interval = parse_duration(opts.get("--interval", "20s")) or 20
    stall = parse_duration(opts.get("--stall", "15m"))
    heartbeat = parse_duration(opts.get("--heartbeat", "5m"))
    last_line, last_print = None, 0.0
    while True:
        s = summarize(path)
        if s["state"] != "running":
            if last_line:
                print(progress_line(s), file=sys.stderr)
            return print_final(s)
        line = progress_line(s)
        key = re.sub(r" \| idle .*$", "", re.sub(r"running [^|]+", "running", line))
        now = time.time()
        if key != last_line or (heartbeat and now - last_print >= heartbeat):
            print(line, flush=True)
            last_line, last_print = key, now
        if stall and s["idle"] >= stall:
            print("[wrapper] STALLED: job %s has shown no activity for %s (it is still running)."
                  % (job_id, fmt_age(s["idle"])), flush=True)
            if "--stop-on-stall" in opts:
                cmd_stop(jobs_dir, job_id)
                return 2
            print("[wrapper] keep waiting: watch %s again; stop it: stop %s" % (job_id, job_id), flush=True)
            return 2
        time.sleep(interval)


def cmd_status(jobs_dir, job_id=None):
    if job_id:
        s = summarize(job_dir(jobs_dir, job_id))
        print(progress_line(s))
        print("  task: " + short(s["label"], 200))
        if s["swarm"]:
            print("  members: " + (", ".join(s["swarm"]["workers"]) or "(none yet)"))
            for p in s["swarm"]["posts"][-5:]:
                print("  board #%s %s: %s" % (p.get("seq", "?"), p.get("agent", "?"), short(p.get("text", ""), 120)))
        if s["text"] and s["state"] == "running":
            print("  latest text: " + short(s["text"][-300:], 300))
        if s["state"] != "running":
            print("  finished; full answer: result %s" % s["id"])
        return 0
    if not os.path.isdir(jobs_dir):
        print("no agy jobs yet")
        return 0
    rows = []
    for name in sorted(os.listdir(jobs_dir), reverse=True)[:10]:
        if os.path.isfile(os.path.join(jobs_dir, name, "meta.json")):
            s = summarize(os.path.join(jobs_dir, name))
            rows.append("%s  %-7s %-8s %-6s %s" % (s["id"], s["state"], fmt_age(s["elapsed"]),
                                                   s["kind"], short(s["label"], 70)))
    print("\n".join(rows) if rows else "no agy jobs yet")
    return 0


def cmd_stop(jobs_dir, job_id):
    path = job_dir(jobs_dir, job_id)
    pid = load_meta(path)["pid"]
    if not alive(pid):
        print("[wrapper] job %s is not running" % job_id)
        return 0
    # SIGINT lets agy finish cleanly and emit an INTERRUPTED result with any partial answer.
    for sig, wait in ((signal.SIGINT, 20), (signal.SIGTERM, 5), (signal.SIGKILL, 2)):
        try:
            if sig == signal.SIGINT:
                os.kill(pid, sig)
            else:
                os.killpg(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.time() + wait
        while time.time() < deadline and alive(pid):
            time.sleep(0.5)
        if not alive(pid):
            break
    print("[wrapper] job %s stopped" % job_id)
    return 0


def cmd_result(jobs_dir, job_id):
    s = summarize(job_dir(jobs_dir, job_id))
    if s["state"] == "running":
        print(progress_line(s))
        print("[wrapper] still running; watch it or check again later", file=sys.stderr)
        return 3
    return print_final(s)


def main(argv):
    if len(argv) < 2:
        die(__doc__.strip())
    cmd, jobs_dir, rest = argv[0], argv[1], argv[2:]
    if cmd == "start":
        if len(rest) < 3:
            die("start needs <kind> <label> <argv...>")
        return cmd_start(jobs_dir, rest[0], rest[1], rest[2:])
    if cmd == "status":
        return cmd_status(jobs_dir, rest[0] if rest else None)
    if not rest:
        die("%s needs a job id (list jobs with /agy:status)" % cmd)
    job_id, opts, i = rest[0], {}, 1
    while i < len(rest):
        if rest[i] == "--stop-on-stall":
            opts[rest[i]] = True
            i += 1
        elif rest[i] in ("--interval", "--stall", "--heartbeat") and i + 1 < len(rest):
            opts[rest[i]] = rest[i + 1]
            i += 2
        else:
            die("unknown option '%s'" % rest[i])
    if cmd == "watch":
        return cmd_watch(jobs_dir, job_id, opts)
    if cmd == "stop":
        return cmd_stop(jobs_dir, job_id)
    if cmd == "result":
        return cmd_result(jobs_dir, job_id)
    die("unknown command '%s'" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
