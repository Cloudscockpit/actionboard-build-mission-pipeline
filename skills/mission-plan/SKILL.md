---
name: mission-plan
description: Write a ActionBoard V5 Mission Plan (Agent Assignments with file ownership, Skills Gap analysis, Risk Register) as Markdown plus a schema.org JSON-LD knowledge graph. Use when the user asks to "write the mission plan", "draft assignments", "show the risk register", or at Steps 3-5 of the ActionBoard V5 mission flow, and whenever a plan must be exported as structured or machine-readable output.
---

# Mission Plan — Markdown + Knowledge Graph

Emits the second of the three ActionBoard V5 mission documents: what each Agent will do, what the
mission cannot yet do, and what could go wrong.

**Read the format reference first:** `${CLAUDE_PLUGIN_ROOT}/kb/mission-knowledge-format.md`.
It defines the JSON-LD envelope, the URN identifier scheme, the schema.org type mapping, the
`actionStatus` vocabulary, and the pre-write validation steps.

## What a plan contains

| Section | Markdown form | Graph node |
|---------|---------------|-----------|
| Agent Assignments | Table: Agent → Task → Files Owned → Depends On → Acceptance | `Action` per row |
| Skills Gap | Table: Capability → Status → Notes | `DefinedTerm` per row |
| Risk Register | Table: Category → Risk → Severity → Mitigation | `Thing` (`additionalType: "Risk"`) per row |

## Procedure

1. **Reuse the mission slug** from the existing `mission-brief`. Read the brief's `.jsonld`
   to recover `urn:voltron:mission:{slug}` rather than re-deriving it from the objective —
   re-deriving drifts, and a drifted slug silently forks the mission into two graphs.
2. **Draft assignments.** One `Action` per Agent task. Enforce the file-ownership rule: no two
   assignments may list the same file in `object`. This is checkable in the graph, so check
   it — group every assignment's `object` `@id`s and confirm no path appears twice.
3. **Run Skills Gap** via the `skills-registry` skill and its `actions-map.json`. Status is
   `covered`, `use-existing-skill:{name}`, or `needs-new-skill`. A registry entry marked
   `conditional` counts as covered only when its `requires` precondition is actually met —
   otherwise record the unmet precondition in Notes.
4. **Build the Risk Register.** Categories: technical, scope, integration, data-loss.
   Severity is `L`, `M`, or `H`. Every risk gets a mitigation, even if that mitigation is
   "accept and monitor".
5. **Write `mission-plan.md`** as three tables, then `mission-plan.jsonld`.
   At plan stage every assignment carries `PotentialActionStatus` — the plan describes
   intent, not outcome, and nothing is `Completed` before the Agents have run.
6. **Update the mission node** so `member` lists every Agent that now has an assignment, and
   `subjectOf` includes the plan.
7. **Validate** per the KB checklist, then report both paths.

## Writing rules

- Each assignment's Acceptance must be observable by someone who did not write the code.
- If a Agent has no work this mission, omit them. Do not pad the table to five rows.
- `Depends On` names another assignment's `@id`, not a prose description — that is what makes
  the dispatch order derivable from the graph instead of from reading the table.
- Files in `object` are repo-relative paths, matching `urn:voltron:file:{path}` exactly.

## The go/no-go gate

The plan is the document the user approves. After writing it, present the three tables and
stop:

> "Mission ready. Reply **go** to dispatch Agents, **no-go** to revise, or **edit <section>**."

Do not dispatch Red, Blue, or Yellow Agent before that approval, and do not write
`mission-report` until the Agents have actually reported.
