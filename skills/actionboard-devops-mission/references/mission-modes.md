# Mission Modes

Three modes. The mode determines **who holds the go/no-go**, not whether the gate
exists. The gate is evaluated in all three.

| Mode | Registry value | Who drives | Gate role |
| --- | --- | --- | --- |
| Guided | `guided` | Human drives, agents assist | No autonomous execution. Where new patterns get registered |
| ActionList | `actionlist` | Item by item, human approves each | Advisory. Stage scores recorded for future eligibility |
| Agent Formation | `formation` | Async, semi-autonomous | Binding. Actions below threshold are held and surfaced, never executed |

The mode recorded on a run is the mode it actually ran in. A run driven by a
human, recorded as `formation` because that was the plan, corrupts the evidence
the gate depends on.

## Selecting the mode

`scripts/gate_check.py` returns a verdict per action. The verdict is the mode
ceiling — you may always run in a **more** supervised mode than the verdict
allows, never a less supervised one.

| Verdict | Maximum mode |
| --- | --- |
| `guided` | Guided |
| `actionlist` | ActionList |
| `autonomous` | Agent Formation |

Two rules the script cannot enforce for you:

1. **Default to Guided for any action with no recorded run history.** The script
   returns `guided` for an empty window, but a brand-new action added mid-mission
   may not be in the registry at all yet.
2. **Never promote an action to Agent Formation inside the same session that
   first registered it.** Same-session runs share too much context to be
   independent evidence.

## Mixed missions

A mission's actions will not share one verdict, and they should not be levelled
to the lowest. Group the plan by verdict and run each group in its own mode:
T1 actions in Formation, the T3 migration in ActionList, the newly registered
pattern in Guided. The mission's mode is a property of each action, not of the
mission.

## Starting a formation

Agent Formation starts on an **explicit go from the operator**, per formation.

There is no implicit go. None of the following are go signals:

- silence
- "sounds good"
- "proceed" on a prior message, about a prior plan
- a previous formation having been approved
- the gate returning `autonomous`

Present the plan and stop. The gate returning `autonomous` means the action is
*eligible* to be run without step-by-step approval — it is not itself the
approval.

If someone proposes turning off the explicit-go requirement, they are proposing
to remove the mechanism. There is usually a real problem underneath — most often
that formations are being planned for actions that should have been ActionList
all along — but the config flag is not the fix.

## Promotion

Promotion is an output of evidence, never a decision made in a planning session.
An action moves up when `gate_check.py` says it has:

- every stage at or above the tier threshold across the scoring window
- the tier's required number of clean, non-backfilled runs
- an operator whose level clears both the tier floor and the autonomy ceiling

The realistic ladder, from the rollout guide:

| Week | State |
| --- | --- |
| 1 | Backfill, classify, fix TODOs, commit the registry. Everything `guided` |
| 2 | Real missions in Guided mode, scoring every stage honestly. First true failure rates appear — usually lower than anyone guessed |
| 3 | T1 actions move to ActionList. Patterns approach threshold; the data stage is the usual laggard |
| 4 | First T1 actions clear the gate |

Week 2 decides whether any of this works. The temptation is to score generously —
marking a stage passed because the run "basically worked". Every generous score is
a future incident with a paper trail saying the pipeline was fine.

**Report every promotion to the operator.** When an action is promoted the
autonomy surface changed, and someone is accountable for it.

## Demotion

Demotion is immediate and automatic. A live pattern that drops below threshold
gets `regressed_at` set, loses autonomy on the spot, and reverts to ActionList.

It does not return to Formation until the tier's full clean-run requirement is met
again at threshold. See `references/formation-gate.md` for regression handling and
what to report.

Demote manually, without waiting for the gate, when:

- the model, model routing, prompt, or skill version changed — the gate suspends
  autonomy when the gate mechanism changes, but does not detect an upstream model
  change on its own
- the action's tier was raised on review
- the target environment changed materially
- the operator changed to someone below the tier's floor or ceiling

## Mode and the user's request

A user asking to run a `guided` action anyway is making a legitimate request. Run
it — in Guided or ActionList mode, with them driving, scoring the stages as you
go. That run becomes evidence.

What does not happen is autonomous execution of an ungated action. The request
changes who drives; it does not change what has been proven.
