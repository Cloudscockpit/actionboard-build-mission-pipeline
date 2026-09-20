---
name: skills-registry
description: ActionBoard V5 AgentFormation skills registry and actions map. Use during Skills Gap analysis (Step 4 of the mission flow) to map mission capabilities to registered action types, responsible Agents, and required tools/skills. Also use when the user asks "what can the Agents do", "list actionboard-v5 actions", or "show the actions map".
---

# ActionBoard V5 AgentFormation — Skills Registry

The registry is the single source of truth for **which Agent handles which action type** and **what tools or skills that action requires**. It is backed by the machine-readable actions map co-located with this skill:

```
skills/skills-registry/actions-map.json
```

## How to use this registry (Black Agent — Step 4)

During Skills Gap analysis:

1. Read `actions-map.json` (use the `Read` tool on the path relative to the plugin root, or `${CLAUDE_PLUGIN_ROOT}/skills/skills-registry/actions-map.json` when the plugin root variable is available).
2. For each capability the mission needs, find the closest matching `action` entry:
   - **Exact or close match found, `status: "covered"`** → classify the capability as `covered`, cite the responsible Agent from the entry.
   - **Match found with non-empty `skills` list** → classify as `use-existing-skill <name>` using the first skill in the list; the responsible Agent invokes it.
   - **Match found with `requires` field** → the capability is conditionally covered. Surface the requirement (e.g., per-site user approval for `live-browser-action`) in the Skills Gap table Notes column.
   - **No match** → classify as `needs-new-skill` and propose a one-line description.
3. When `skill-creator` scaffolds a new skill mid-mission, append a new entry to the actions map in your Mission Summary so the user can commit it (the plugin's copy of `actions-map.json` is read-only at runtime — registry updates ship with the next plugin version).

## Actions map schema

Each entry in `actionTypes`:

| Field | Meaning |
|-------|---------|
| `action` | Kebab-case action type identifier (e.g., `api-integration`) |
| `agent` | The responsible Agent agent (`red-agent`, `blue-agent`, `green-agent`, `yellow-agent`, or `black-agent`) |
| `description` | One line: what this action type covers |
| `requiredTools` | Built-in Claude Code tools the Agent needs (must be in the Agent's frontmatter `tools:`) |
| `skills` | Skills the Agent invokes for this action (empty = built-ins suffice) |
| `requires` | Optional precondition outside this action (e.g., per-site approval, or a prior document) |
| `status` | `covered` \| `conditional` \| `experimental` |

## Answering "what can the Agents do"

When the user asks directly, render the actions map as a table grouped by Agent:
Agent → Action types → What it needs. Keep it under 30 lines; link to `actions-map.json` for the full data.

## Registering a new action type

New action types are added by editing `actions-map.json` in the plugin repository (https://github.com/Cloudscockpit/actionboard-build-mission-pipeline), bumping the plugin version, and reinstalling. An entry MUST name exactly one responsible Agent — if an action seems to need two Agents, split it into two entries with a `dependsOn` note in the description.
