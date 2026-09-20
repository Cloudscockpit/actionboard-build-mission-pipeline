---
name: mission-report
description: Write a ActionBoard V5 Mission Report recording what each Agent shipped, blocked on, or deferred, as Markdown plus a schema.org JSON-LD knowledge graph. Use when the user asks to "write the mission report", "summarize the mission", "what shipped", or after Agents report back at the end of the ActionBoard V5 mission flow, and whenever a report must be exported as structured or machine-readable output.
---

# Mission Report — Markdown + Knowledge Graph

Emits the third and final ActionBoard V5 mission document: the outcome of every assignment, recorded
against the same graph nodes the plan created.

**Read the format reference first:** `${CLAUDE_PLUGIN_ROOT}/kb/mission-knowledge-format.md`.
The report's value depends entirely on reusing the plan's identifiers — a report that mints
fresh `@id`s records nothing, because nothing links back to what was promised.

## What a report contains

| Section | Content | Graph effect |
|---------|---------|-------------|
| Outcome | One line per assignment: shipped / blocked / deferred | `Action.actionStatus` transition |
| Mission Log | Each Agent's report verbatim-ish, in dispatch order | `Action.result` / `Action.error` |
| Success Criteria | Each brief criterion marked met or unmet, with evidence | `DefinedTerm` + evidence |
| Deferred | What was cut, and why | `Action` left `Potential`, with a reason |

## Procedure

1. **Load the plan's graph.** Read `mission-plan.jsonld` and reuse every `@id` — mission,
   assignments, Agents, files. The report does not create assignments; it resolves them.
2. **Transition each assignment's status** using the KB's `actionStatus` vocabulary:
   Agent reported `done` → `CompletedActionStatus`; Agent reported `blocked` →
   `FailedActionStatus` plus an `error` string naming the blocker; never dispatched →
   left at `PotentialActionStatus` with a `result` explaining the deferral.
3. **Record results honestly.** `result` carries what the Agent actually produced. If a Agent
   reported `done` but its acceptance criterion was never checked, that is not
   `CompletedActionStatus` — mark it `Active` and say the verification is outstanding.
4. **Check success criteria against evidence**, not against assignment status. An assignment
   can complete while its criterion still fails. Cite the evidence — a command's output, a
   test result, a file that now exists — for each criterion marked met.
5. **Set `endDate`** on the mission node.
6. **Write `mission-report.md`**, then `mission-report.jsonld`. Validate per the KB checklist
   and report both paths.

## Writing rules

- Report what happened, not what was supposed to happen. A mission where two of five
  assignments blocked is a useful record; a report that rounds it to "mission complete" is
  not, and the graph will contradict it.
- Every `FailedActionStatus` needs an `error` a reader can act on. "Failed" alone is noise.
- Do not quietly drop an assignment that was never dispatched. Deferred work stays in the
  graph with its reason, or the next mission rediscovers it as new.
- Keep the Markdown short. The detail lives in the graph; the Markdown is the summary someone
  reads in thirty seconds.

## What the accumulated graph answers

Because Agent and file identifiers are global across missions (see the KB's identifier scheme),
a directory of mission reports answers questions no single report can: which files block most
often, which Agent's assignments most frequently need a second pass, which success criteria
keep recurring unmet. Mention this to the user once they have more than one mission on disk —
it is the reason the format exists.
