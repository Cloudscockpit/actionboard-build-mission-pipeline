#!/usr/bin/env python3
"""Compute formation gate verdicts for registered actions.

Reads an action registry, evaluates each action's run history against its
risk tier thresholds and the operator's maturity level, and returns a verdict
of autonomous / actionlist / guided with the reason.

Usage:
    python gate_check.py --registry registry.json --operator-level L4
    python gate_check.py --registry registry.json --operator-level L4 --mission m-204
    python gate_check.py --registry registry.json --operator-level L4 --json

See references/formation-gate.md for the rules this implements.
"""

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

STAGES = ["orchestrator", "data", "analysis", "action", "defense"]

# tier -> (threshold, minimum_clean_runs, minimum_operator_level)
TIER_RULES = {
    "T1": (0.90, 3, 2),
    "T2": (0.90, 5, 2),
    "T3": (0.95, 10, 4),
    "T4": (None, None, 6),  # never autonomous
}

# operator level -> highest tier permitted autonomously (0 = none)
AUTONOMY_CEILING = {1: 0, 2: 1, 3: 1, 4: 2, 5: 2, 6: 3, 7: 3}

SCORING_WINDOW = 20
STALENESS_DAYS = 90


def parse_level(raw):
    text = str(raw).strip().upper().lstrip("L")
    try:
        level = int(text)
    except ValueError:
        raise SystemExit(f"Could not read operator level: {raw!r}. Use L1-L7.")
    if not 1 <= level <= 7:
        raise SystemExit(f"Operator level out of range: {raw!r}. Use L1-L7.")
    return level


def tier_number(tier):
    return int(str(tier).upper().lstrip("T"))


def parse_ts(value):
    if not value:
        return None
    text = str(value).replace("Z", "+00:00")
    try:
        ts = datetime.fromisoformat(text)
    except ValueError:
        return None
    return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)


def window_runs(runs):
    """Most recent runs within the scoring window and not stale."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=STALENESS_DAYS)
    dated = []
    for run in runs:
        ts = parse_ts(run.get("completed_at"))
        if ts is None or ts >= cutoff:
            dated.append((ts, run))
    dated.sort(key=lambda pair: (pair[0] is not None, pair[0]))
    return [run for _, run in dated[-SCORING_WINDOW:]]


def stage_rates(runs):
    """Per-stage pass rate. Missing or unscoreable stages count as failures."""
    rates = {}
    for stage in STAGES:
        if not runs:
            rates[stage] = 0.0
            continue
        passed = sum(1 for r in runs if r.get("stages", {}).get(stage) is True)
        rates[stage] = passed / len(runs)
    return rates


def clean_runs(runs):
    """Clean runs that count toward eligibility.

    Backfilled runs are excluded. A CI record proves the deploy exited zero;
    it does not prove the analysis stage was correct or that the defense stage
    caught anything, because nobody was scoring those at the time. Counting
    backfill toward autonomy grants trust that was never measured.
    """
    return sum(
        1 for r in runs
        if r.get("provenance") != "backfilled"
        and all(r.get("stages", {}).get(stage) is True for stage in STAGES)
    )


def backfilled_count(runs):
    return sum(1 for r in runs if r.get("provenance") == "backfilled")


def evaluate(action, operator_level):
    tier = str(action.get("risk_tier", "")).upper()
    if tier not in TIER_RULES:
        return {
            "action_id": action.get("id"),
            "name": action.get("name"),
            "tier": tier or "unclassified",
            "verdict": "guided",
            "reason": "Action is not classified. Classify before planning execution.",
            "stage_rates": {},
            "clean_runs": 0,
            "window_size": 0,
        }

    threshold, min_runs, min_level = TIER_RULES[tier]
    runs = window_runs(action.get("runs", []))
    rates = stage_rates(runs)
    clean = clean_runs(runs)
    ceiling = AUTONOMY_CEILING[operator_level]

    result = {
        "action_id": action.get("id"),
        "name": action.get("name"),
        "tier": tier,
        "stage_rates": rates,
        "clean_runs": clean,
        "backfilled_runs": backfilled_count(runs),
        "window_size": len(runs),
    }

    if tier == "T4":
        result["verdict"] = "actionlist" if operator_level >= min_level else "guided"
        result["reason"] = (
            "T4 is never eligible for autonomy. Human go/no-go on every execution."
            if operator_level >= min_level
            else f"T4 requires L{min_level} or above; operator is L{operator_level}."
        )
        return result

    if operator_level < min_level:
        result["verdict"] = "guided" if operator_level < 2 else "actionlist"
        result["reason"] = (
            f"Operator L{operator_level} is below the L{min_level} floor for {tier}."
        )
        return result

    if not runs:
        result["verdict"] = "guided"
        result["reason"] = "No run history in the scoring window. Register the pattern in Guided mode."
        return result

    if action.get("regressed_at"):
        result["verdict"] = "actionlist"
        result["reason"] = (
            f"Regression recorded at {action['regressed_at']}. "
            f"Requires {min_runs} clean runs at threshold to re-qualify."
        )
        return result

    failing = {s: r for s, r in rates.items() if r < threshold}
    if failing:
        worst = min(failing, key=failing.get)
        result["verdict"] = "actionlist"
        result["reason"] = (
            f"{worst} stage at {failing[worst]:.0%}, below the {threshold:.0%} "
            f"threshold for {tier}."
        )
        return result

    if clean < min_runs:
        result["verdict"] = "actionlist"
        backfilled = result["backfilled_runs"]
        note = (
            f" ({backfilled} backfilled run(s) recorded as context; backfill "
            "does not count toward eligibility)" if backfilled else ""
        )
        result["reason"] = (
            f"{clean} scored clean run(s) of {min_runs} required for {tier}{note}."
        )
        return result

    if tier_number(tier) > ceiling:
        result["verdict"] = "actionlist"
        result["reason"] = (
            f"Gate conditions met, but L{operator_level} caps autonomy at "
            f"T{ceiling}. Escalate the operator or keep human approval."
        )
        return result

    result["verdict"] = "autonomous"
    result["reason"] = (
        f"All five stages at or above {threshold:.0%} across {len(runs)} run(s); "
        f"{clean} clean. Operator L{operator_level} clears {tier}."
    )
    return result


def render(results, operator_level):
    order = {"guided": 0, "actionlist": 1, "autonomous": 2}
    results = sorted(results, key=lambda r: (order[r["verdict"]], r["name"] or ""))

    print(f"\nFormation gate check — operator L{operator_level}")
    print("=" * 72)

    for r in results:
        print(f"\n[{r['verdict'].upper()}] {r['name']}  ({r['tier']})")
        print(f"  {r['reason']}")
        if r["stage_rates"] and r["window_size"]:
            scores = "  ".join(
                f"{s[:4]}:{rate:.0%}" for s, rate in r["stage_rates"].items()
            )
            print(f"  stages: {scores}   window: {r['window_size']}  clean: {r['clean_runs']}")

    counts = {v: sum(1 for r in results if r["verdict"] == v) for v in order}
    print("\n" + "-" * 72)
    print(
        f"autonomous: {counts['autonomous']}   "
        f"actionlist: {counts['actionlist']}   "
        f"guided: {counts['guided']}"
    )
    if counts["autonomous"]:
        print("\nAgent Formation requires an explicit go from the operator.")
    print()


def main():
    ap = argparse.ArgumentParser(description="ActionBoard formation gate check")
    ap.add_argument("--registry", required=True, help="path to registry JSON")
    ap.add_argument("--operator-level", required=True, help="L1-L7")
    ap.add_argument("--mission", help="filter to actions tagged with this mission id")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a report")
    args = ap.parse_args()

    try:
        with open(args.registry) as fh:
            registry = json.load(fh)
    except FileNotFoundError:
        raise SystemExit(f"Registry not found: {args.registry}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Registry is not valid JSON: {exc}")

    actions = registry.get("actions", registry if isinstance(registry, list) else [])
    if args.mission:
        actions = [a for a in actions if args.mission in a.get("missions", [])]

    if not actions:
        raise SystemExit("No actions to evaluate.")

    level = parse_level(args.operator_level)
    results = [evaluate(a, level) for a in actions]

    if args.json:
        json.dump({"operator_level": level, "results": results}, sys.stdout, indent=2)
        print()
    else:
        render(results, level)

    # Non-zero exit when nothing is cleared for autonomy, so CI can branch on it.
    return 0 if any(r["verdict"] == "autonomous" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
