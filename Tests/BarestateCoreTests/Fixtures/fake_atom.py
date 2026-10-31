#!/usr/bin/env python3
"""A stand-in for the Atom runtime: JSON lines on stdin, one reply line per request on stdout.

Behaviour comes from the plan file named by FAKE_ATOM_PLAN (a JSON object keyed
"<spawn>:<ordinal>", the process's place in FAKE_ATOM_LOG's start lines and the request's ordinal
within that process; "default" applies to the rest). Every line received and every reply written
is appended, with the pid and a timestamp, to FAKE_ATOM_LOG.

Plan fields: delay (seconds before replying), hang (never reply), garbage (write junk lines first),
stale (write a valid-looking reply with this id first), abstain, error, exit (die without replying).
The point returned is derived from the instruction: "p<N>" gives x=N, y=N+1.
"""
import json
import os
import queue
import re
import sys
import threading
import time

PLAN = {}
if os.environ.get("FAKE_ATOM_PLAN"):
    with open(os.environ["FAKE_ATOM_PLAN"]) as plan_file:
        PLAN = json.load(plan_file)
LOG = os.environ.get("FAKE_ATOM_LOG")


def log(kind, text):
    if LOG:
        with open(LOG, "a") as out:
            out.write(json.dumps({"t": time.time(), "pid": os.getpid(), "kind": kind,
                                  "text": text}) + "\n")


def emit(text):
    log("out", text)
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def point_reply(request_id, instruction):
    match = re.search(r"p(\d+)", instruction)
    x = int(match.group(1)) if match else 500
    return {"id": request_id, "ok": True, "result": {
        "action": "click", "normalized": {"x": x, "y": x + 1},
        "pixel": {"x": x * 0.8, "y": (x + 1) * 0.6}, "image": {"width": 800, "height": 600},
        "raw": "<s>click", "duration_ms": 1}}


def read_requests(lines):
    """Logs each line the moment it arrives, even while the main loop is busy, so a client that
    sends the next request before the last reply shows up in the log."""
    for line in sys.stdin:
        log("in", line.rstrip("\n"))
        lines.put(line)
    lines.put(None)


def main():
    lines = queue.Queue()
    threading.Thread(target=read_requests, args=(lines,), daemon=True).start()
    log("start", "")
    spawn = 1
    if LOG:
        with open(LOG) as seen:
            spawn = sum(1 for line in seen if json.loads(line)["kind"] == "start")
    ordinal = 0
    while (line := lines.get()) is not None:
        try:
            request = json.loads(line)
        except ValueError:
            emit(json.dumps({"id": None, "ok": False,
                             "error": {"type": "JSONDecodeError", "message": "bad json"}}))
            continue
        if not isinstance(request, dict):
            emit(json.dumps({"id": None, "ok": False,
                             "error": {"type": "ValueError", "message": "not an object"}}))
            continue
        request_id = request.get("id")
        params = request.get("params") or {}
        if request.get("method") == "health":
            emit(json.dumps({"id": request_id, "ok": True,
                             "result": {"model": "Atom", "verified": True, "loaded": False}}))
            continue
        ordinal += 1
        plan = PLAN.get(f"{spawn}:{ordinal}", PLAN.get("default", {}))
        if plan.get("exit"):
            sys.exit(1)
        if plan.get("hang"):
            time.sleep(3600)
        if plan.get("garbage"):
            emit("this is not json")
            emit('{"id": "' + str(request_id) + '", "ok": tr')
            emit(json.dumps({"id": None, "ok": False,
                             "error": {"type": "ValueError", "message": "orphan"}}))
            emit(json.dumps([1, 2, 3]))
            emit("")
        if plan.get("stale"):
            emit(json.dumps(point_reply(plan["stale"], "p999")))
        if plan.get("delay"):
            time.sleep(plan["delay"])
        if plan.get("error"):
            emit(json.dumps({"id": request_id, "ok": False,
                             "error": {"type": "ValueError", "message": "bad instruction"}}))
        elif plan.get("abstain"):
            emit(json.dumps({"id": request_id, "ok": True, "result": {
                "action": "abstain", "raw": "", "reason": "No valid point returned",
                "duration_ms": 1}}))
        else:
            emit(json.dumps(point_reply(request_id, params.get("instruction", ""))))


if __name__ == "__main__":
    main()
