#!/usr/bin/env python3
"""Bridge GitHub Actions jobs to Flow pipeline nodes.

Flow token comes from $FLOW_TOKEN (GitHub secret) or ~/.riscv-flow/auth.json
(on the runner host). All Flow object IDs are passed by the workflow.

Subcommands:
  trigger   --pipeline ID [--set KEY=VALUE ...]   PATCH DYNAMIC, quickRun,
                                                   restore, emit history_id
  wait-node --history H --label L                  poll one node, stream log,
                                                   exit 0 on success
  show      --history H                            print node/pod table
"""
import argparse
import fcntl
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("FLOW_URL", "https://flow.damo.xrvm.cn").rstrip("/")
PROJECT = int(os.environ.get("FLOW_PROJECT", "150"))


def load_token():
    token = os.environ.get("FLOW_TOKEN")
    if token:
        return token.strip()
    path = os.path.expanduser("~/.riscv-flow/auth.json")
    return json.load(open(path))["user"]


TOKEN = load_token()


def req(path, method="GET", payload=None, raw=False, no_cache=False):
    url = BASE + path
    if no_cache:
        url += ("&" if "?" in url else "?") + f"_={int(time.time() * 1000)}"
    data = json.dumps(payload).encode() if payload is not None else None
    # systemd-resolved on the runner host intermittently fails to resolve the
    # Flow host for a single lookup; retry only that failure mode.
    for attempt in range(4):
        r = urllib.request.Request(url, data=data, method=method)
        r.add_header("Authorization", f"Bearer {TOKEN}")
        r.add_header("Cookie", f"china_fusion_flow_cookie={TOKEN}")
        r.add_header("Flow-Token", f"Bearer {TOKEN}")
        r.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(r, timeout=120) as f:
                body = f.read().decode("utf-8", "replace")
            return body if raw else json.loads(body)
        except urllib.error.URLError as exc:
            if not isinstance(exc.reason, socket.gaierror) or attempt == 3:
                raise
            time.sleep(3 * (attempt + 1))


def template(pid):
    return req(f"/kamala/api/v1/task/template/detail/{pid}?project={PROJECT}")


def pipeline_summary(hid):
    return req(f"/kamala/api/v1/queue/layout/summary/{hid}?project={PROJECT}",
               no_cache=True)["result"]


def pipeline_layout(hid):
    return req(f"/kamala/api/v1/queue/layout/{hid}?project={PROJECT}", no_cache=True)


def step_summary(node_id):
    return req(f"/kamala/api/v1/queue/step/summary/{node_id}?project={PROJECT}",
               no_cache=True)["result"]


def pod_log(output_path, pod_name):
    parts = output_path.split("/")
    i = parts.index("flow")
    subpath = "/".join(parts[i:i + 2])
    return req(f"/runtime/{subpath}/{pod_name}/flow/log/{pod_name}.log",
               raw=True, no_cache=True)


def out(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")
    print(f"{key}={value}")


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(text + "\n")


def set_dynamic(tpl, values):
    originals = {}
    for n in tpl.get("nodes", []):
        if n.get("type") != "DYNAMIC":
            continue
        for ed in n.get("exDatas") or []:
            key = ed.get("key")
            if key in values:
                originals[key] = ed.get("value")
                ed["value"] = values[key]
    missing = set(values) - set(originals)
    if missing:
        raise SystemExit(f"unknown DYNAMIC keys: {sorted(missing)}")
    return originals


def patch_template(pid, tpl):
    resp = req(f"/kamala/api/v1/task/template/detail/{pid}?project={PROJECT}",
               "PATCH", tpl)
    if not resp.get("success"):
        raise SystemExit(f"template patch failed: {str(resp)[:300]}")


def trigger(pid, values):
    lock = open(f"/tmp/flow-bridge-{pid}.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        tpl = template(pid)
        originals = set_dynamic(tpl, values)
        patch_template(pid, tpl)
        try:
            resp = req("/kamala/api/v1/task/quickRun", "POST",
                       {"project": PROJECT, "trigger_user": "github-actions",
                        "id": pid})
            hid = (resp.get("result") or {}).get("historyId")
            if not hid:
                raise SystemExit(f"quickRun failed: {str(resp)[:300]}")
        finally:
            tpl = template(pid)
            set_dynamic(tpl, originals)
            patch_template(pid, tpl)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
    print(f"triggered pipeline {pid} history {hid}: {values}")
    out("history_id", hid)
    return hid


def nodes(hid):
    return pipeline_layout(hid)["nodes"]


def node_pod(node):
    for step in step_summary(node["node_id"]):
        for p in step.get("pod") or []:
            return p
    return None


def wait_node(hid, label, interval, timeout):
    start = time.time()
    last_log = 0.0
    while True:
        try:
            node = next((n for n in nodes(hid) if n["label"] == label), None)
        except Exception as exc:
            print(f"layout query failed: {exc}")
            node = None
        if node:
            status = node["status"]
            pod = node_pod(node)
            if pod and time.time() - last_log > 300:
                try:
                    text = pod_log(pod["output_path"], pod["name"])
                    print(f"--- {label} pod={pod['name']} status={status} "
                          f"({len(text)} B) ---")
                    print("\n".join(text.splitlines()[-20:]))
                except Exception as exc:
                    print(f"log unavailable: {exc}")
                last_log = time.time()
            if status in ("success", "error", "failed", "canceled", "cancelled"):
                pod_name = pod["name"] if pod else "-"
                print(f"=== node {label} {status} pod={pod_name} ===")
                if pod:
                    try:
                        text = pod_log(pod["output_path"], pod["name"])
                        tail = "\n".join(text.splitlines()[-120:])
                        print(f"--- {label} final log tail ---\n{tail}")
                        summary(f"<details><summary>{label} log tail</summary>\n\n"
                                f"```\n{tail}\n```\n</details>")
                    except Exception as exc:
                        print(f"final log unavailable: {exc}")
                summary(f"| {label} | {status} | `{pod_name}` |")
                return 0 if status == "success" else 1
        if timeout and time.time() - start > timeout:
            print(f"timeout waiting for {label}")
            return 1
        time.sleep(interval)


def show(hid):
    s = pipeline_summary(hid)[0]
    print(f"pipeline {hid} result={s['result']} updated={s['update_time']}")
    for n in nodes(hid):
        pod = node_pod(n)
        print(f"  {n['nodeType']:9} {n['label']:34} {n['status']:10} "
              f"{pod['name'] if pod else '-'}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("trigger")
    p.add_argument("--pipeline", type=int, required=True)
    p.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")

    p = sub.add_parser("wait-node")
    p.add_argument("--history", type=int, required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--interval", type=int, default=30)
    p.add_argument("--timeout", type=int, default=0)

    p = sub.add_parser("show")
    p.add_argument("--history", type=int, required=True)

    a = ap.parse_args()
    if a.cmd == "trigger":
        trigger(a.pipeline, dict(kv.split("=", 1) for kv in a.set))
    elif a.cmd == "wait-node":
        sys.exit(wait_node(a.history, a.label, a.interval, a.timeout))
    else:
        show(a.history)


if __name__ == "__main__":
    main()
