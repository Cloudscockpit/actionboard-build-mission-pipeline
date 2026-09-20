# The Formation Gate

The rules `scripts/gate_check.py` implements. Every number here is read from that
script's constants. If you change one, change both — Claude reads this file, the
script reads its own constants, and a mismatch produces a confident, wrong
explanation of why something was blocked.

## The five stages

A run is scored on five independent stages. Each is a boolean.

| Stage | Key | Passes when |
| --- | --- | --- |
| Orchestrator | `orchestrator` | The right actions were selected, in the right order, for the stated goal |
| Data | `data` | Inputs were located, current, and complete |
| Analysis | `analysis` | The plan derived from the data was correct for the goal |
| Action | `action` | The effect landed as specified, verified against the end condition |
| Defense / audit | `defense` | No policy violation, no unlogged side effect, evidence captured |

**An unscoreable stage is a failed stage.** `stage_rates()` counts a stage as
passed only when its value is exactly `true`. Missing, `null`, "n/a", and
"couldn't tell" all score as failures. This is deliberate: unscoreable stages are
the single most common way a success rate inflates.

**Retry-to-green is a failure.** A run that only went green on a second attempt
sets `first_attempt: false`, and the stage that needed the retry scores failed.

## Thresholds per tier

| Tier | Stage threshold | Clean runs required | Operator floor | Autonomy |
| --- | --- | --- | --- | --- |
| T1 | 90% | 3 | L2 | Eligible |
| T2 | 90% | 5 | L2 | Eligible |
| T3 | 95% | 10 | L4 | Eligible |
| T4 | — | — | L6 | **Never autonomous** |

The threshold applies to **every stage independently**, not to an average. Four
stages at 100% and one at 80% is a fail, and the reported reason names the
lagging stage.

T4 never reaches `autonomous` at any operator level or any success rate. An L6+
operator gets `actionlist` — human go/no-go on every execution. Below L6, T4 is
`guided`.

## Operator autonomy ceiling

Clearing an action's own thresholds is not sufficient. The operator's certified
maturity level caps the highest tier that may run autonomously:

| Operator | Highest tier permitted autonomously |
| --- | --- |
| L1 | none |
| L2 – L3 | T1 |
| L4 – L5 | T2 |
| L6 – L7 | T3 |

An action that meets every threshold but exceeds the operator's ceiling returns
`actionlist` with the reason naming the cap. The remedy is a more senior
operator or continued human approval — never a threshold edit.

## The scoring window

- **Window size: the 20 most recent runs.** Older runs are context, not evidence.
- **Staleness: 90 days.** A run with a `completed_at` older than 90 days drops
  out of the window entirely. A run with an unparseable or absent timestamp is
  retained rather than silently discarded.
- Rates and clean-run counts are computed over the window only. A pattern that
  was reliable a year ago and untouched since has no evidence, not good evidence.

## What counts as a clean run

A clean run has **all five stages true** and `provenance` that is not
`backfilled`.

Backfilled runs — seeded from git or CI history by `scripts/backfill_registry.py`
— are written with `provenance: "backfilled"` and are excluded from the clean
count. A CI record proves a job exited zero. It does not prove the orchestrator
chose correctly, that the input data was current, or that a side effect was
logged, because nobody was scoring those stages at the time. Backfill gives you a
populated registry and an honest failure baseline. It does not give you autonomy.

### Backfill is blocked twice over, and the second block is the visible one

The provenance exclusion is not the only thing holding a backfilled action back,
and it is usually not the reason the operator sees.

`scripts/backfill_registry.py` does not leave the unobserved stages blank. It
writes them as explicit failures:

```python
"stages": {
    "orchestrator": False,
    "data":         False,
    "analysis":     False,
    "action":       succeeded,   # the only stage with evidence
    "defense":      False,
}
```

So a backfilled action fails two independent rules:

1. **Stage thresholds.** Four stages sit at 0%, far below any tier's threshold.
2. **The clean-run count.** Every run is `provenance: "backfilled"` and excluded.

Evaluation order decides which one the operator is shown. The stage check is
step 6 and the clean-run check is step 7, so a real backfilled registry reports:

```
[ACTIONLIST] Deploy api  (T2)
  orchestrator stage at 0%, below the 90% threshold for T2.
  stages: orch:0%  data:0%  anal:0%  acti:100%  defe:0%   window: 12  clean: 0
```

**Not** the "backfill does not count toward eligibility" note, which only appears
once the stage rates are high enough to reach step 7. Someone reading that first
message may conclude the pipeline is broken. It is not — it is reporting that
four of five stages have never been measured.

This reframes the most common adoption argument. "We have 200 green deploys, that
IS the evidence" describes, in the registry's own terms, 200 runs in which one
stage of five passed and four were recorded as failures — 800 stage failures, not
200 successes. The 200 green deploys are real and they are worth having; they are
evidence about the action stage and nothing else. The other four stages have no
history at all, and a stage with no history scores zero.

The answer to that conversation is not a provenance edit or a threshold change.
It is that ActionList mode keeps every deploy moving at full speed while real
stage scores accumulate, and T2 needs only 5 clean runs — days at most team
cadences, not months.

**Runs sharing a `session_id` are not independent evidence.** Never promote an
action on same-session runs alone. If the script cleared something suspiciously
fast, the session ids are probably missing from the records.

## Evaluation order

`evaluate()` returns on the first condition that matches. The order matters,
because it determines which reason the operator is shown:

1. **Unclassified tier** → `guided`. Classify before planning execution.
2. **T4** → `actionlist` at L6+, otherwise `guided`. Never `autonomous`.
3. **Operator below the tier floor** → `actionlist` (or `guided` below L2).
4. **No runs in the window** → `guided`. Register the pattern in Guided mode.
5. **`regressed_at` is set** → `actionlist` until re-qualified.
6. **Any stage below threshold** → `actionlist`, naming the worst stage.
7. **Clean runs below the minimum** → `actionlist`, with backfilled runs noted
   as context.
8. **Tier above the operator's ceiling** → `actionlist`.
9. Otherwise → `autonomous`.

## Regression handling

When a live pattern drops below threshold, set `regressed_at` on the action. It
immediately loses autonomy and reverts to ActionList mode. The flag clears only
after the tier's full clean-run requirement is met again at threshold — a T3
regression needs 10 clean runs, not one good day.

This is not the system failing. It is the system doing its only job. Report:

- the drop, with the stage that moved
- the run where it started
- what changed: model version, model routing, prompt, skill version, tool, upstream
  data, or operator

The `environment` block on each run exists so this question is answerable. The
gate suspends autonomy when the gate mechanism itself changes; it does **not**
automatically detect an upstream model routing change. That stays a manual item
on your change checklist.

## Diagnosing a stage that lags

Be diagnostic, not apologetic. "Needs more runs" is not a diagnosis.

| Lagging stage | Usual cause |
| --- | --- |
| Data ~70% | A source is stale, or an input is ambiguous. The normal laggard; moves quickly once fixed |
| Analysis ~70% | The goal is underspecified |
| Action ~70%, others clean | The end condition is wrong, not the execution |
| Everything stuck at 0% for weeks | End conditions are too vague to score at all. Check those before touching thresholds |

State the specific remediation and how many clean runs it would take to clear.

## Running the check

```bash
python "${CLAUDE_PLUGIN_ROOT}/skills/actionboard-devops-mission/scripts/gate_check.py" \
  --registry <registry.json> \
  --operator-level <L1-L7> \
  [--mission <mission-id>] \
  [--json]
```

`--mission` filters to actions tagged with that id in their `missions` array.
`--json` emits the full result set instead of the rendered report.

**Exit code: 0 if any action cleared for autonomy, 1 otherwise.** In CI this is
normal for weeks, so wire the reporting job with `continue-on-error: true`. A
check that is always red gets ignored, and then so does the real signal when it
appears. Fail the build on registry *integrity* defects instead — an action with
no `end_condition`, a T4 marked autonomous, a run with missing stage scores.

## What never happens

Never override a `guided` verdict because the user asks. If the user wants the
action run anyway, that is a legitimate request — run it in Guided or ActionList
mode with them driving. What does not happen is autonomous execution of an
ungated action.

Confidence reported by a model at decision time is not evidence. Only recorded,
scored history is.
