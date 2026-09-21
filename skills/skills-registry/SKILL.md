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
   - **Match found with `requires` field** → the capability is conditionally covered. A `conditional` entry counts as `covered` **only once its `requires` is actually met** — until then it is an open precondition, not a solved capability. Surface the requirement (e.g., per-site user approval for `live-browser-action`) in the Skills Gap table Notes column.
   - **Match found whose `requires` names another action** → that other action is a separate capability and needs its own Skills Gap row, planned and dispatched first. `remote-mission-execution` requires a prior successful `remote-gateway-connect`; classify it `conditional — blocked on remote-gateway-connect` and never mark it covered on the strength of the gateway entry alone. A gateway that is registered but not verified by `openshell whoami` does not satisfy the precondition either.
   - **Match found whose `requires` names an operator-supplied fact** → the fact is a mission input, not something an Agent can produce. `remote-gateway-connect` needs a gateway URL, an OIDC issuer, and a freshly minted one-time token from the ActionBoard pod console. No endpoint, issuer, or identity-pool default ships with this plugin, and a dev pool is never a substitute. If the operator has not supplied them, the capability is **not** covered — say so in Notes and ask, rather than planning around it.
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

## Remote execution action types

Two entries cover running a mission on a **remote ActionBoard cloud OpenShell gateway** instead of the local daemon. Both are `black-agent` and both are `conditional`.

| Action | Skill | The condition |
|--------|-------|---------------|
| `remote-gateway-connect` | `pod-connect` | Operator supplies the gateway URL, the OIDC issuer, and a one-time token; the user confirms the `--dry-run` plan; `openshell whoami` and a non-empty `workspace list` both succeed. |
| `remote-mission-execution` | `mission-harness` | A prior successful `remote-gateway-connect`, and `--gateway <name>` passed explicitly so the harness cannot drift onto whichever gateway is active. |

Three things to get right about this pair:

- **They are two entries, not one.** Connecting is operator-facing and gates everything after it; running the harness is mission work. Splitting them is what lets a plan show the gateway as its own dispatchable step with its own go/no-go.
- **The one-time token is consumed by the first successful connect.** A retry needs a fresh token from the pod console. Never plan a step that assumes the token can be reused, and never put it in a command line — it goes in `ACTIONBOARD_POD_TOKEN` or through `--token-stdin`.
- **Pod, gateway, and workspace are three different things.** The pod is the ActionBoard tenancy and billing label, the gateway is the OpenShell control plane, the workspace is the isolation boundary inside it. A Skills Gap row that conflates them plans a mission into the wrong tenant.

`remote-mission-execution` forks to the `sandbox-warden` subagent, which is why its `requiredTools` are Black Agent's (`Skill`, `Bash`) and not the warden's — the map names the responsible Agent, not every process involved.

## Answering "what can the Agents do"

When the user asks directly, render the actions map as a table grouped by Agent:
Agent → Action types → What it needs. Keep it under 30 lines; link to `actions-map.json` for the full data. Mark `conditional` entries as conditional in that table — a user reading it as a capability list should not discover the precondition only after the mission starts.

## Registering a new action type

New action types are added by editing `actions-map.json` in the plugin repository (https://github.com/Cloudscockpit/actionboard-build-mission-pipeline), bumping the plugin version, and reinstalling. An entry MUST name exactly one responsible Agent — if an action seems to need two Agents, split it into two entries with a `dependsOn` note in the description.
