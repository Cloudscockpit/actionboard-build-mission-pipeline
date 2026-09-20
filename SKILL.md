---
name: actionboard-devops-mission
description: Run a maturity-gated ActionBoard DevOps mission — discover and register deployment actions, classify them by risk, score the five formation stages per run, and enforce the 90% formation gate before any action executes autonomously. Use this skill whenever the user asks to run a mission, deploy or ship a feature through ActionBoard, register or classify actions, check whether an action is cleared for autonomous execution, investigate a gate failure or stage regression, or produce a mission report. Also use it when the user mentions maturity gates, formation success rate, risk tiers, ActionLists, Action Graph patterns, or autonomy levels, even if they do not name ActionBoard directly.
---

# ActionBoard DevOps Mission

Run a DevOps mission end to end under ActionBoard's maturity-gated execution model.

The central rule this skill enforces: **an action does not execute autonomously until it has proven it can.** Proof means recorded history — multiple completed runs, every formation stage above the gate threshold, and an operator whose certified maturity level clears the action's risk tier. Confidence scores reported by a model at decision time are not proof and are never sufficient on their own.

## When the gate applies

Every mission runs in one of three modes. The mode determines who holds the go/no-go, not whether the gate exists.

| Mode | Who drives | Gate role |
| --- | --- | --- |
| Guided | Human drives, agents assist | No autonomous execution. This is where new patterns get registered |
| ActionList | Item by item, human approves each | Gate advisory. Stage scores recorded for future eligibility |
| Agent Formation | Async, semi-autonomous | Gate binding. Actions below threshold are held and surfaced, never executed |

Default to Guided mode for any action with no recorded run history. Never promote an action to Agent Formation mode inside the same session that first registered it.

## Mission workflow

Work through these phases in order. Do not skip ahead to execution because an action "looks safe" — the point of the sequence is that safety is measured, not assessed.

### 1. Load mission context

Establish four things before touching anything:

- **The goal**, stated as an outcome with a verifiable end condition. If the user's goal cannot be checked as done or not done, stop and resolve that first. An unclear goal makes every downstream success rate meaningless.
- **The operator's maturity level** (L1–L7). If unknown, ask. Do not assume.
- **The registry state** — which of the actions this mission needs are already registered, and what their run history shows.
- **The environment** — target, blast radius, whether this is a first run of the pattern.

### 2. Discover and register actions

Decompose the goal into discrete actions. An action is one unit of work with a single effect that can succeed or fail on its own.

For each action, record: the steps, the tools touched, the data read or written, the decisions made, and the end condition. Write these to the action registry (`assets/action-registry.schema.json` defines the shape). Actions already in the registry are matched by pattern, not recreated — a mission that re-registers an existing action loses its history and resets its eligibility, which is the most common way teams accidentally lock themselves out of autonomy.

### 3. Classify risk

Classify every action on four dimensions before planning execution. Read `references/risk-classification.md` for the rubric and the tier mapping.

Classification output is a risk tier (T1 routine through T4 restricted) attached to the action in the registry. The tier travels with the action into every ActionList that uses it.

### 4. Check the gate

Run the gate check before building the execution plan, not after:

```bash
python scripts/gate_check.py --registry <registry.json> --operator-level <L1-L7> --mission <mission-id>
```

The script returns a per-action verdict: `autonomous`, `actionlist`, or `guided`, with the reason. Read `references/formation-gate.md` for the threshold rules, stage definitions, and how regressions are handled.

Never override a `guided` verdict because the user asks. If the user wants the action run anyway, that is a legitimate request — run it in Guided or ActionList mode with them driving. What does not happen is autonomous execution of an ungated action.

### 5. Plan and present

Produce the execution plan grouped by verdict. The plan states, per action: mode, risk tier, current stage scores, what the gate is waiting on, and the rollback path.

Present the plan and stop. Agent Formation mode starts on an explicit go from the operator. There is no implicit go — silence, "sounds good", and "proceed" on a prior message are not go signals for a new formation.

### 6. Execute and score

During execution, score each of the five stages on every action:

| Stage | Succeeds when |
| --- | --- |
| Orchestrator | The right actions were selected in the right order for the stated goal |
| Data | Inputs were located, current, and complete |
| Analysis | The plan derived from the data was correct for the goal |
| Action | The effect landed as specified, verified against the end condition |
| Defense / audit | No policy violation, no unlogged side effect, evidence captured |

A stage that cannot be scored counts as a failure, not as absent. Unscoreable stages are how success rates inflate.

### 7. Report

Write the mission report using `assets/mission-report-template.md`. The report is the evidence artifact — it is what an auditor reads and what the next run of this pattern starts from. Include stage scores, gate movements, and any regression.

## Handling gate failures

When an action fails the gate, the useful response is diagnostic, not apologetic. Identify which stage is dragging the rate down and what the failures have in common. A data stage at 70% usually means a source is stale or an input is ambiguous. An analysis stage at 70% usually means the goal is underspecified. An action stage at 70% with the others clean usually means the end condition is wrong, not the execution.

State the specific remediation and how many clean runs it would take to clear. "Needs more runs" is not a diagnosis.

## Handling regressions

A previously autonomous action that drops below threshold loses autonomy immediately and reverts to ActionList mode. This is not a failure of the system — it is the system doing its only job. Report the drop, the run where it started, and what changed (model version, prompt, tool, upstream data, operator).

## Reference files

- `docs/enabling-in-your-repo.md` — install, repo layout, config, CI wiring, and backfilling a repo that already has deployment history
- `references/risk-classification.md` — the four dimensions, tier mapping, policy-restricted classes
- `references/formation-gate.md` — thresholds, stage scoring, maturity floors, regression handling
- `references/mission-modes.md` — mode selection, promotion and demotion rules
- `scripts/gate_check.py` — computes per-action verdicts from registry history
- `scripts/backfill_registry.py` — seeds a registry from git or CI history; backfilled runs are context, never eligibility
- `assets/action-registry.schema.json` — registry record shape
- `assets/mission-report-template.md` — required report structure

## Naming

Use "five agents" or "the formation". The agents are orchestrator, data, analysis, action, and defense/audit. Do not use retired internal codenames in any generated artifact, commit message, report, or customer-facing output.
