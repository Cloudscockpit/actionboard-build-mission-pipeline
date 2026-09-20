# Mission Report — <mission-id>

> Copy this file, fill every field, and keep it with the registry. This report is
> the evidence artifact: it is what an auditor reads and what the next run of
> these patterns starts from. A field you cannot fill is a finding, not a blank —
> write why it could not be filled.
>
> Related: the ActionBoard V5 `mission-report` skill emits the same outcome record as
> Markdown plus schema.org JSON-LD. Use it when the report needs to join a
> queryable mission history; use this template when the report is the gate
> evidence record.

| | |
| --- | --- |
| **Mission** | `<mission-id>` |
| **Goal** | <the outcome, with its verifiable end condition> |
| **Operator** | <name> (L<1-7>) |
| **Date** | <YYYY-MM-DD> |
| **Registry** | `<path/to/registry.json>` |
| **Target** | <environment / blast radius> |
| **Modes used** | <guided / actionlist / formation> |

## 1. Outcome

<Two or three sentences. Was the goal's end condition met — true or false? If
partially, say which actions landed and which did not. No hedging: the end
condition was checkable or it was not, and if it was not, that is the first
finding.>

## 2. Gate check at plan time

Verdicts from `gate_check.py` before execution, and the mode each action actually
ran in.

| Action | Tier | Verdict | Mode run | Reason given by the gate |
| --- | --- | --- | --- | --- |
| <name> | T<n> | autonomous / actionlist / guided | <mode> | <verbatim reason string> |

**Explicit go recorded:** <who approved the formation, when — or "no formation in
this mission">

Any action where the mode run is less supervised than the verdict allowed is a
control failure. Record it here, in bold, with what happened.

## 3. Stage scores

One row per run. Every stage is `true` or `false` — never blank, never "n/a". An
unscoreable stage is `false`, and the reason goes in Notes.

| Action | Run id | Orch | Data | Analysis | Action | Defense | First attempt | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| <name> | <run-id> | ✓/✗ | ✓/✗ | ✓/✗ | ✓/✗ | ✓/✗ | yes/no | <ambiguity, retry, abort reason> |

**Clean runs this mission:** <n> (all five stages true, `provenance: scored`)

Runs that only went green on retry have `first_attempt: no`, and the stage that
needed the retry is scored `✗`.

## 4. Gate movements

What changed in the autonomy surface as a result of this mission.

| Action | Before | After | Trigger |
| --- | --- | --- | --- |
| <name> | actionlist | autonomous | Met 5 clean runs at 90% for T2 |

If nothing moved, write "No gate movements." — that is a normal and reportable
outcome, especially in the first weeks.

## 5. Regressions

| Action | Stage that dropped | Rate before → after | First bad run | What changed |
| --- | --- | --- | --- | --- |
| <name> | data | 95% → 78% | <run-id> | <model version / prompt / tool / upstream source / operator> |

For each regression, state: `regressed_at` set (yes/no), the mode it reverted to,
and how many clean runs at threshold are required to re-qualify.

If none, write "No regressions." Do not omit the section.

## 6. Registry changes

- **Actions registered:** <names, with tier and rationale>
- **Actions matched to existing patterns:** <names — confirm you matched on
  `pattern_id` rather than re-registering; re-registration resets history and
  eligibility>
- **Tier changes:** <action, old → new, who reviewed>
- **End conditions or rollback paths corrected:** <which, and why the old one was
  wrong>

## 7. Held actions

Actions the gate blocked, with the diagnosis. "Needs more runs" is not a
diagnosis — name the lagging stage and what it indicates.

| Action | Verdict | Lagging stage | Diagnosis | Clean runs to clear |
| --- | --- | --- | --- | --- |
| <name> | actionlist | data 70% | Source X is stale; input Y is ambiguous | <n> |

## 8. Follow-ups

- [ ] <specific remediation, owner, and which stage rate it is expected to move>

---

**Scoring attestation:** scores in this report were recorded during execution, not
reconstructed afterwards. Ambiguous stages were scored as failures with the
ambiguity written into Notes.
