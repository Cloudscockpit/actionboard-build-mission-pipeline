#!/usr/bin/env python3
"""Seed an action registry from a repo's existing deployment history.

Backfill answers one question: which patterns does this repo already run, and
how often. It does NOT establish eligibility. Every run it writes is marked
`"provenance": "backfilled"` and is excluded from the clean-run count by
gate_check.py.

The reason is worth stating plainly: a CI record tells you a job exited zero.
It does not tell you whether the orchestrator picked the right actions, whether
the input data was current, or whether a side effect went unlogged. Nobody was
scoring those stages at the time, so there is no evidence about them. Backfill
gives you a populated registry and a realistic failure baseline. It does not
give you autonomy.

Usage:
    # From git history, grouping by conventional-commit scope
    python backfill_registry.py --git --since 2026-03-01 --out registry.json

    # From a CI export (newline-delimited JSON)
    python backfill_registry.py --ci-log deploys.ndjson --out registry.json

    # Merge into an existing registry instead of creating one
    python backfill_registry.py --git --since 2026-03-01 --out registry.json --merge

Expected CI record shape (one JSON object per line):
    {"pattern": "deploy-api", "completed_at": "2026-08-14T10:02:00Z",
     "status": "success", "env": "prod", "sha": "abc123"}
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone

STAGES = ["orchestrator", "data", "analysis", "action", "defense"]

CONVENTIONAL = re.compile(r"^(\w+)(?:\(([^)]+)\))?!?:")

# Heuristic tier hints. These are starting points for a human to correct,
# never final classifications — see references/risk-classification.md.
TIER_HINTS = [
    (re.compile(r"secret|credential|key|token|iam|auth|rbac", re.I), "T4"),
    (re.compile(r"billing|payment|invoice|charge|refund", re.I), "T4"),
    (re.compile(r"migrat|schema|backfill|delete|drop|purge", re.I), "T3"),
    (re.compile(r"infra|terraform|cluster|network|dns|prod", re.I), "T3"),
    (re.compile(r"deploy|release|rollout|publish", re.I), "T2"),
    (re.compile(r"docs|lint|format|test|chore|ci", re.I), "T1"),
]


def guess_tier(name):
    for pattern, tier in TIER_HINTS:
        if pattern.search(name):
            return tier
    return "T2"


def git_history(since, path="."):
    """Group commits by conventional-commit scope, or by touched top-level dir."""
    fmt = "%H%x1f%cI%x1f%s%x1e"
    cmd = ["git", "-C", path, "log", f"--since={since}", f"--pretty=format:{fmt}"]
    try:
        raw = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        raise SystemExit("git not found on PATH.")
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"git log failed: {exc.stderr.strip()}")

    groups = defaultdict(list)
    for record in raw.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 3:
            continue
        sha, when, subject = parts[0], parts[1], parts[2]

        match = CONVENTIONAL.match(subject)
        if match:
            kind, scope = match.group(1), match.group(2)
            pattern = f"{kind}-{scope}" if scope else kind
        else:
            pattern = "unscoped"

        groups[pattern].append(
            {"completed_at": when, "status": "success", "sha": sha, "subject": subject}
        )
    return groups


def ci_history(path):
    groups = defaultdict(list)
    with open(path) as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                print(f"  skipped malformed line {line_no}", file=sys.stderr)
                continue
            pattern = record.get("pattern") or record.get("workflow") or "unscoped"
            groups[pattern].append(record)
    return groups


def to_action(pattern, records):
    runs = []
    for record in records:
        succeeded = str(record.get("status", "success")).lower() in {
            "success", "succeeded", "passed", "ok", "0"
        }
        runs.append({
            "run_id": record.get("sha") or record.get("id") or "",
            "completed_at": record.get("completed_at"),
            "mode": "guided",
            "provenance": "backfilled",
            "stages": {
                # Only the action stage has evidence: the job ran and reported
                # an outcome. The other four were never observed, and an
                # unscored stage is a failed stage.
                "orchestrator": False,
                "data": False,
                "analysis": False,
                "action": succeeded,
                "defense": False,
            },
            "notes": record.get("subject") or record.get("env") or "",
        })

    runs.sort(key=lambda r: r.get("completed_at") or "")
    succeeded = sum(1 for r in runs if r["stages"]["action"])
    rate = succeeded / len(runs) if runs else 0.0

    return {
        "id": pattern,
        "name": pattern.replace("-", " ").replace("_", " ").strip().capitalize(),
        "pattern_id": pattern,
        "risk_tier": guess_tier(pattern),
        "risk_rationale": "BACKFILL HEURISTIC — review and correct before first mission.",
        "end_condition": "TODO: state how this action is verified done.",
        "rollback": "TODO: state the rollback path.",
        "registered_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "backfill": {
            "source_runs": len(runs),
            "historical_success_rate": round(rate, 3),
            "note": "Action stage only. Other stages were never observed.",
        },
        "runs": runs,
    }


def main():
    ap = argparse.ArgumentParser(description="Seed an ActionBoard registry from repo history")
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--git", action="store_true", help="read git log")
    source.add_argument("--ci-log", help="path to newline-delimited JSON CI export")
    ap.add_argument("--since", default="6 months ago", help="git --since value")
    ap.add_argument("--repo", default=".", help="repo path for --git")
    ap.add_argument("--out", required=True, help="registry path to write")
    ap.add_argument("--merge", action="store_true", help="merge into an existing registry")
    ap.add_argument("--min-runs", type=int, default=2,
                    help="drop patterns with fewer runs than this (default 2)")
    args = ap.parse_args()

    groups = git_history(args.since, args.repo) if args.git else ci_history(args.ci_log)
    groups = {k: v for k, v in groups.items() if len(v) >= args.min_runs}

    if not groups:
        raise SystemExit("No patterns found. Widen --since or lower --min-runs.")

    actions = [to_action(pattern, records) for pattern, records in sorted(groups.items())]

    registry = {"registry_version": "1", "actions": []}
    if args.merge and os.path.exists(args.out):
        with open(args.out) as fh:
            registry = json.load(fh)
        existing = {a.get("pattern_id") or a.get("id") for a in registry.get("actions", [])}
        added = [a for a in actions if a["pattern_id"] not in existing]
        skipped = len(actions) - len(added)
        registry.setdefault("actions", []).extend(added)
        print(f"Merged {len(added)} new pattern(s); {skipped} already registered.")
    else:
        registry["actions"] = actions

    with open(args.out, "w") as fh:
        json.dump(registry, fh, indent=2)
        fh.write("\n")

    print(f"\nWrote {args.out} — {len(registry['actions'])} action(s).\n")
    print("Every backfilled run is marked provenance=backfilled and does NOT count")
    print("toward the gate. Before the first mission, for each action:")
    print("  1. Correct the risk tier (the heuristic is a starting point, not a verdict)")
    print("  2. Write the end condition — it must be checkable true or false")
    print("  3. Write the rollback path")
    print("\nThen run gate_check.py. Expect everything to come back guided. That is correct.")


if __name__ == "__main__":
    sys.exit(main())
