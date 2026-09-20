---
name: mission-brief
description: Write a ActionBoard V5 Mission Brief (objective, scope, out of scope, success criteria, constraints) as Markdown plus a schema.org JSON-LD knowledge graph. Use when the user asks to "write a mission brief", "draft the brief", "scope this mission", or at Step 1 of the ActionBoard V5 mission flow, and whenever a brief must be exported as structured or machine-readable output.
---

# Mission Brief — Markdown + Knowledge Graph

Emits the first of the three ActionBoard V5 mission documents in both human and machine form.

**Read the format reference first:** `${CLAUDE_PLUGIN_ROOT}/kb/mission-knowledge-format.md`.
It defines the JSON-LD envelope, the URN identifier scheme, the schema.org type mapping, and
the pre-write validation steps. Do not improvise identifiers or types — the three mission
documents merge into one graph only because they share that scheme.

## What a brief contains

| Section | Content | Graph node |
|---------|---------|-----------|
| Objective | One sentence. What the mission achieves, not how. | `Project.description` |
| Scope | Bulleted, concrete, each item independently checkable. | `ItemList` of `DefinedTerm` |
| Out of Scope | What a reader might reasonably assume is included but isn't. | `ItemList` of `DefinedTerm` |
| Success Criteria | Observable, testable. "Returns 200", not "works well". | `DefinedTerm` per criterion |
| Constraints | Assumptions, deadlines, tech limits, things held fixed. | `ItemList` of `DefinedTerm` |

## Procedure

1. **Derive the slug** from the objective: kebab-case, drop articles, truncate to 48 chars.
   Every identifier in this and later mission documents is built on it, so fix it now and
   never change it mid-mission.
2. **Confirm the output directory** with the user — default `./actionboard-v5-missions/{date}-{slug}/`.
   Ask before creating a top-level directory in someone's repo.
3. **Write `mission-brief.md`.** Lead with a one-line objective, then the five sections as
   headed lists. Keep it under a page; a brief that needs scrolling has scope problems.
4. **Write `mission-brief.jsonld`.** Emit the `Project` node, the `Report` node for the brief
   itself, and one `DefinedTerm` per scope item, criterion, and constraint. Reference the
   Agents in `member` only once assignments exist — at brief stage the mission has no members
   yet, so omit `member` rather than guessing.
5. **Validate** per the KB's pre-write checklist: parse the JSON, resolve every `@id`
   reference, confirm the enumerations.
6. **Report both paths** to the user and state that the brief is Step 1 of 3.

## Writing rules

- If the objective is vague, ask ONE clarifying question before drafting. A brief built on a
  guess sends every downstream Agent in the wrong direction, and the plan inherits the error.
- Every success criterion must name how it is checked. If you cannot say how it is checked,
  it belongs in Scope, not Success Criteria.
- Out of Scope is not optional. An empty Out of Scope means the boundary was never tested.
- State assumptions in Constraints explicitly rather than leaving them implied.

## Relationship to the other mission documents

The brief establishes `urn:voltron:mission:{slug}` and its success criteria. `mission-plan`
attaches assignments to it and `mission-report` records their outcomes, both by `@id`
reference. Write the brief first; if a plan already exists without one, write the brief from
the plan's `about` node rather than inventing a second mission identifier.
