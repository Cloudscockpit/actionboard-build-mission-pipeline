# Enabling the ActionBoard DevOps Mission in your repo

A guide for wiring maturity-gated execution into an existing repository — including one with months of deployment history already behind it.

**Contents**

1. [What you are installing](#1-what-you-are-installing)
2. [Install](#2-install)
3. [Repo layout](#3-repo-layout)
4. [Configuration](#4-configuration)
5. [Starting from an existing repo with history](#5-starting-from-an-existing-repo-with-history)
6. [Wiring the gate into CI](#6-wiring-the-gate-into-ci)
7. [The first four weeks](#7-the-first-four-weeks)
8. [Best practices](#8-best-practices)
9. [Failure modes](#9-failure-modes)

---

## 1. What you are installing

Three things, and it helps to be clear which is which:

| Component | What it is | Where it lives |
| --- | --- | --- |
| The skill | Instructions Claude Code loads when a mission starts | `.claude/skills/actionboard-devops-mission/` |
| The registry | Your actions, their risk tiers, and their scored run history | `.actionboard/registry.json`, committed |
| The gate | A script that turns registry history into an execution verdict | `scripts/gate_check.py` inside the skill |

The registry is the part that matters. The skill is replaceable and the gate is a hundred lines of Python; the registry is the accumulated evidence about your own pipeline, and it is the thing you cannot regenerate if you lose it. Treat it as source, not as cache.

## 2. Install

```bash
# From the repo root
mkdir -p .claude/skills
cp -r /path/to/actionboard-devops-mission .claude/skills/

# Verify Claude Code sees it
ls .claude/skills/actionboard-devops-mission/SKILL.md
```

The skill triggers on mission language — "run a mission", "ship this through ActionBoard", "is this action cleared", "check the gate". You do not need a slash command, though one helps if your team prefers explicit invocation:

`.claude/commands/mission.md`
```markdown
---
description: Run an ActionBoard DevOps mission with the maturity gate
---
Run an ActionBoard DevOps mission for: $ARGUMENTS

Use the actionboard-devops-mission skill. Load the registry from
.actionboard/registry.json and the operator level from .actionboard/config.json.
Run the gate check before planning. Do not start a formation without an explicit go.
```

Commit both. A skill that lives only on one laptop produces run history nobody else can verify, which defeats the point.

## 3. Repo layout

```
your-repo/
├── .actionboard/
│   ├── registry.json          # actions, tiers, run history — COMMIT THIS
│   ├── config.json            # operator levels, thresholds, paths
│   └── reports/               # mission reports, one per run
├── .claude/
│   ├── skills/
│   │   └── actionboard-devops-mission/
│   └── commands/
│       └── mission.md
└── .github/workflows/
    └── gate.yml               # optional: gate check in CI
```

Commit `registry.json`. Yes, it changes on every mission, and yes, that means merge conflicts on the `runs` arrays when two people run missions in parallel. That is a real cost and it is worth paying: a registry in a database is a registry your reviewers cannot see in a diff, and the whole value of the mechanism is that the evidence is inspectable. If the conflicts become unmanageable, split the registry per action (`.actionboard/actions/<pattern-id>.json`) before you move it out of the repo.

Do not commit `reports/` if they contain customer data. Point them at an artifact store instead and commit the index.

## 4. Configuration

`.actionboard/config.json`

```json
{
  "registry": ".actionboard/registry.json",
  "reports": ".actionboard/reports/",
  "operators": {
    "jarjis@cloudscockpit.io": 6,
    "dev1@example.com": 3,
    "dev2@example.com": 2
  },
  "environments": {
    "dev":     { "max_tier_autonomous": "T2" },
    "staging": { "max_tier_autonomous": "T2" },
    "prod":    { "max_tier_autonomous": "T1" }
  },
  "require_explicit_go": true,
  "scoring_window": 20,
  "staleness_days": 90
}
```

`environments` is an additional ceiling on top of the operator ceiling, and the most restrictive of the two wins. Starting prod at `T1` is deliberate. You can raise it later on evidence; raising it on optimism is how teams discover their classification was wrong in production.

`require_explicit_go` should stay `true`. If someone asks to flip it for convenience, the honest framing is that they are asking to remove the mechanism, not to configure it.

## 5. Starting from an existing repo with history

This is the common case, and the naive approach — start the registry empty and run everything in Guided mode for three weeks — is a hard sell to a team that has been deploying this service twice a week for a year.

The backfill script gives you a populated registry without pretending you have evidence you do not have.

### Run the backfill

From git history, grouped by conventional-commit scope:

```bash
python .claude/skills/actionboard-devops-mission/scripts/backfill_registry.py \
  --git --since "6 months ago" \
  --out .actionboard/registry.json
```

From a CI export (newline-delimited JSON, one record per deploy):

```bash
python .claude/skills/actionboard-devops-mission/scripts/backfill_registry.py \
  --ci-log deploys.ndjson \
  --out .actionboard/registry.json
```

Each record needs at minimum a pattern name, a completion timestamp, and a status:

```json
{"pattern": "deploy-api", "completed_at": "2026-08-14T10:02:00Z", "status": "success", "env": "prod"}
```

Most CI systems can produce this. For GitHub Actions, `gh run list --json name,conclusion,createdAt --limit 500` is close enough after a light reshape.

### What backfill gives you, and what it does not

Backfilled runs are written with `"provenance": "backfilled"` and are **excluded from the clean-run count**. They populate your action inventory, give you a realistic historical success rate, and show you which patterns you actually run. They do not move the gate.

The reason is structural, not conservatism. Your CI history records one bit per deploy: the job exited zero or it did not. That is evidence about the **action** stage. It says nothing about whether the orchestrator selected the right steps, whether the input data was current, whether the analysis was correct for the goal, or whether a side effect went unlogged — because nobody was scoring those stages at the time. An unscored stage is a failed stage, so a backfilled run scores 1/5 by construction.

If you run the gate check straight after a backfill, everything returns `actionlist` or `guided`. That is the correct output, not a bug.

### Fix the three TODO fields

Backfill writes placeholders you have to fill before the first mission:

1. **`risk_tier`** — the script guesses from the pattern name using keyword heuristics. It will get some wrong. Review every one against `references/risk-classification.md`, and when in doubt classify one tier higher and let evidence bring it down.
2. **`end_condition`** — how the action is verified done, stated so it can be checked true or false. This is the field teams skip and the one that most often causes an inflated success rate later: if the end condition is vague, the action stage scores pass whenever the job exits zero, which is exactly the blindness you installed this to fix.
3. **`rollback`** — the path back. An action with no stated rollback should not reach T2 autonomy regardless of its history.

Budget an hour per twenty actions for this. It is the highest-leverage hour in the whole installation.

### Prune aggressively

Backfill over six months of a busy repo will produce patterns you do not care about. Delete them. A registry with forty actions where eight are real is worse than a registry with eight, because the gate check output becomes something nobody reads.

Rule of thumb: keep a pattern if it has run at least three times and has a real effect outside the repo. Drop lint, formatting, and docs-only patterns unless they deploy something.

## 6. Wiring the gate into CI

`gate_check.py` exits `0` when at least one action is cleared for autonomy and `1` otherwise, so it branches cleanly.

`.github/workflows/gate.yml`
```yaml
name: Formation gate
on: [pull_request]

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.11' }
      - name: Gate check
        run: |
          python .claude/skills/actionboard-devops-mission/scripts/gate_check.py \
            --registry .actionboard/registry.json \
            --operator-level "${{ vars.OPERATOR_LEVEL || 'L2' }}" \
            | tee gate-report.txt
        continue-on-error: true
      - name: Comment verdicts
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '```\n' + fs.readFileSync('gate-report.txt', 'utf8') + '\n```'
            });
```

Use `continue-on-error: true` here. The gate reporting "nothing is autonomous yet" is normal for weeks and should not turn every PR red — a check that is always failing gets ignored, and then so does the real signal when it appears.

Add a second job that **does** fail the build on a registry integrity problem: an action with no `end_condition`, a T4 marked autonomous, or a run with missing stage scores. Those are defects, not status.

## 7. The first four weeks

| Week | What happens | What to expect |
| --- | --- | --- |
| 1 | Backfill, classify, fix TODOs, commit the registry | Everything `guided`. Team asks why they installed this |
| 2 | Run real missions in Guided mode; score every stage honestly | First real failure rates appear, usually lower than anyone guessed |
| 3 | Move T1 actions to ActionList; keep scoring | First patterns approach threshold. Data stage is usually the laggard |
| 4 | First T1 actions clear the gate | The mechanism starts paying |

Week 2 is the one that decides whether this works. The temptation is to score generously — mark a stage pass because the run "basically worked". Every generous score is a future incident with a paper trail that says the pipeline was fine.

## 8. Best practices

**Score honestly or do not score.** An inflated rate is worse than no rate, because it produces confident autonomy on an untested pattern. If a stage is ambiguous, score it failed and write the ambiguity in the notes.

**One action, one effect.** If an action can partially succeed, it is two actions. Partial success is unscoreable, and unscoreable stages count as failures, so compound actions never clear the gate — correctly, but confusingly.

**Write the end condition before the first run, not after.** An end condition written after a failure gets written to match what happened.

**Keep the registry in review.** Tier changes should go through PR review like any other change. A tier that can be edited without a reviewer is a tier that drifts down under deadline pressure.

**Re-verify after a model or prompt change.** The gate suspends autonomy when the gate mechanism itself changes; it does not automatically detect a model routing change upstream. Add that to your change checklist manually until you have it wired.

**Report gate movements to the operator.** When an action is promoted, someone should know the autonomy surface changed. They are accountable for it.

**Do not let the skill file drift from the gate script.** If you change a threshold in `config.json`, the reference docs in the skill should say the same number. Claude reads the docs; the script reads the config; a mismatch produces confident, wrong explanations of why something was blocked.

## 9. Failure modes

**Everything sits at `guided` for a month.** Usually the end conditions are vague, so the action stage cannot be scored, so nothing accumulates. Check the end conditions first, not the thresholds.

**A pattern clears the gate suspiciously fast.** Check whether its runs share a `session_id`. Runs inside one session share too much context to be independent evidence, and the skill forbids promoting on same-session runs alone. If the script cleared it, the session ids are missing from the records.

**The data stage is the persistent laggard.** This is the normal result and usually means a source is stale or an input is ambiguous rather than that anything is broken. Fix the source; the rate moves quickly.

**Someone proposes flipping `require_explicit_go`.** They are proposing to remove the mechanism. There may be a real problem underneath — usually that formations are being planned for actions that should have been ActionList mode all along — but the config flag is not the fix.

**The registry becomes a merge-conflict tax.** Split per action before moving it to a database. Keep it in the repo as long as you can stand it; inspectability is most of the value.
