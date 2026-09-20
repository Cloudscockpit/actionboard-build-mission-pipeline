# ActionBoard V5 AgentFormation

Turn one objective into a reviewed plan, then execute it with five parallel agents that never
touch the same file. **Nothing runs until you approve.**

For Claude Code and Claude Cowork.

```
/start-mission add a /health endpoint to the express app that returns service version
```

> **Landing page:** [`docs/index.html`](docs/index.html) — setup for both Claude Code and Cowork,
> and the full guide to adding your own skills for the Agents.

## What you get back

Black Agent drafts the plan, sends Green Agent on read-only recon first, then stops:

```markdown
## Mission Brief
Objective     Expose service version and uptime on an unauthenticated GET /health.
Out of scope  Auth, rate limiting, Prometheus metrics, k8s probe wiring
Success       1. GET /health returns 200 with {status, version, uptime}
              2. version matches package.json
              3. Integration test passes in CI
Constraints   Express 4.x, no new runtime dependencies

## Agent Assignments
| Agent   | Task                              | Files Owned           | Depends On | Acceptance                  |
|--------|-----------------------------------|-----------------------|------------|-----------------------------|
| Red    | Implement GET /health             | src/routes/health.js  | —          | curl returns 200 + version  |
| Blue   | Read version from package.json    | src/config/version.js | —          | matches package.json        |
| Yellow | Integration test for the route    | test/health.test.js   | Red, Blue  | npm test passes             |

## Skills Gap
| Capability         | Status  | Notes                        |
|--------------------|---------|------------------------------|
| route handler      | covered | code-implementation -> Red   |
| version at boot    | covered | api-integration -> Blue      |
| integration test   | covered | test-authoring -> Yellow     |

## Risk Register
| Category  | Risk                                    | Sev | Mitigation                         |
|-----------|-----------------------------------------|-----|------------------------------------|
| technical | /health leaks build metadata            | M   | Return semver only, never SHA/env  |
| scope     | Existing 404 handler shadows the route  | L   | Register before catch-all          |

Mission ready. Reply **go** to dispatch Agents, **no-go** to revise, or **edit <section>**.
```

Reply `go` and Red and Blue run **in parallel** — their file sets don't overlap, so they can't
collide — then Yellow runs once both report. Each Agent returns `done` or `blocked`, and
blocked work stays in the report with its reason instead of quietly disappearing.

That file-ownership column is the whole trick: it's what makes parallel dispatch safe, and
it's checked before anything is dispatched rather than discovered as a merge conflict.

## Why the gate matters

The plan is a cheap artifact. Reading four tables costs you thirty seconds; discovering
halfway through that the mission misunderstood your scope costs a lot more. Every mission
stops at go/no-go, and `edit <section>` lets you fix one table without redoing the rest.

## The Agents

| Agent | Role |
|------|------|
| **Black** | Mission planner. Plans, delegates, gates, reports. |
| **Red** | Rapid execution — builds features, writes code. |
| **Blue** | Data & integrations — APIs, schemas, plumbing. |
| **Green** | Acquire knowledge & data — codebase analysis, read-only (graphify-aware). |
| **Yellow** | Quality & defense — tests, security, verification. |
| `sandbox-warden` | Owns OpenShell sandbox lifecycle — provisioning, policy iteration, teardown. |

## Sandbox isolation

Each agent can run inside a kernel-isolated OpenShell sandbox with deny-all egress
and a policy audit trail. The profile an agent gets is what grants or withholds the
ability to mutate real systems, so the mapping matters:

| Agent | Profile | Policy | Can mutate? |
|---|---|---|---|
| Black | `orchestrator` | `orchestrator.yaml` | No — model endpoint and pod control only |
| Green | `data` | `data.yaml` | No — read-only REST on data sources |
| Blue | `analysis` | `analysis.yaml` | No — read-only plus local inference |
| **Red** | `action` | `action.yaml` | **Yes** — `enforcement: enforce`, explicit per-path allow |
| Yellow | `defense` | `defense.yaml` | No — read-only, `enforcement: audit` |

Red is the only agent that mutates, which follows from its role: it writes code and
ships implementations. Yellow reviews and verifies, so it gets read-only with audit
enforcement — it observes what *would* have been denied without blocking.

> **Note for anyone porting policies from the standalone OpenShell plugin:** that
> plugin bound `action` to Yellow and `defense` to Red — the reverse of the agent
> roles here. The policy files themselves are unchanged; only the agent each one is
> assigned to was corrected. Check any policy you carry over against this table.

Three non-agent profiles also ship: `train` (GPU, registry + object store only),
`inference` (local model server), and `scratch` (untrusted code, no egress at all).

## Installation

### Claude Code

In any Claude Code session:

```
/plugin marketplace add Cloudscockpit/actionboard-build-mission-pipeline
/plugin install actionboard-v5-agentformation@actionboard-v5-agentformation
```

If the install summary reports `Run /reload-plugins to activate.`, run `/reload-plugins`.
Otherwise the plugin is already active and `/start-mission` is available.

### Claude Cowork

No terminal needed — this is done through the Cowork interface, not the chat box:

1. Open **Customize** in the sidebar, then **Plugins**.
2. Select **Add marketplace** and enter `Cloudscockpit/actionboard-build-mission-pipeline`.
3. **ActionBoard V5 AgentFormation** appears alongside your other plugins. Select it and choose **Install**.
4. Open the installed plugin to review its skills and agents before enabling them.

Then type `/start-mission` followed by what you want done, in plain English:

```
/start-mission organize the files in my project folder and tell me what's outdated
```

ActionBoard V5 shows you a mission plan and waits — nothing happens until you reply `go`.

## Mission documents as a knowledge base

Every mission document is emitted twice: **Markdown** for people, **schema.org JSON-LD** for
machines. JSON-LD + schema.org is the open format
[Google's Knowledge Graph Search API](https://developers.google.com/knowledge-graph) returns
and the one Google recommends for structured data, so mission output drops into a graph store
or a search index without a transform step.

| Skill | Writes | Covers |
|-------|--------|--------|
| `mission-brief` | `mission-brief.md` + `.jsonld` | Objective, scope, success criteria, constraints |
| `mission-plan` | `mission-plan.md` + `.jsonld` | Agent Assignments, Skills Gap, Risk Register |
| `mission-report` | `mission-report.md` + `.jsonld` | What shipped, what blocked, what was deferred |

The three documents share one URN identifier scheme, so their `@graph` arrays concatenate into
a single valid knowledge base. Agent and file identifiers are **global** rather than
per-mission — that is what makes a directory of missions worth querying: which files block
most often, which Agent's assignments need a second pass, which success criteria keep coming
back unmet.

Red Agent's assignment from the mission above, after it reported `done`:

```json
{
  "@type": "Action",
  "@id": "urn:voltron:mission:add-health-endpoint:assignment:1",
  "name": "Implement GET /health",
  "agent":  { "@id": "urn:voltron:lion:red" },
  "object": { "@id": "urn:voltron:file:src/routes/health.js" },
  "actionStatus": "https://schema.org/CompletedActionStatus"
}
```

Agent status maps onto schema.org's `ActionStatusType`, so a plan and a report are the *same*
graph differing only in `actionStatus` — `Potential` while awaiting your go, `Completed` or
`Failed` once the Agent reports. Because `urn:voltron:file:src/routes/health.js` is the same
node in every mission that touches that file, ten missions later you can ask which files
accumulate the most `FailedActionStatus` assignments.

Full type mapping, identifier scheme, status vocabulary, and a longer worked example:
[kb/mission-knowledge-format.md](kb/mission-knowledge-format.md).

## Skills registry & actions map

The plugin ships a machine-readable registry of everything the Agents can do:

- **Skill:** `actionboard-v5-agentformation:skills-registry` — used by Black Agent during Skills Gap
  analysis, or ask it directly ("what can the Agents do?")
- **Data:** [skills/skills-registry/actions-map.json](skills/skills-registry/actions-map.json)
  — each entry maps an action type → responsible Agent → required tools/skills → status

| Action type | Agent | Status |
|-------------|------|--------|
| code-implementation, file-scaffolding | Red | covered |
| api-integration, database-schema, data-pipeline | Blue | covered |
| codebase-recon, web-research | Green | covered |
| test-authoring, security-review | Yellow | covered |
| mission-brief-authoring, mission-plan-authoring, mission-report-authoring | Black Agent | covered |
| skill-scaffolding | Black Agent | covered (asks approval first) |
| live-browser-action | Black Agent | conditional — per-site user approval; credentials always handed to you |

To register a new action type, edit `actions-map.json`, bump the plugin version, and reinstall.

## What ships

**Command:** `/start-mission`

**Agents:** `black-agent`, `red-agent`, `blue-agent`, `green-agent`, `yellow-agent`

**Skills:**

| Skill | Purpose |
|-------|---------|
| `mission-brief` | Write a Mission Brief as Markdown + schema.org JSON-LD |
| `mission-plan` | Write assignments, skills gap, and risk register as Markdown + JSON-LD |
| `mission-report` | Record each assignment's outcome against the plan's graph nodes |
| `skills-registry` | The actions map — which Agent handles what, and what it needs |
| `browser-actions` | Conduct rules for driving a real browser during a mission |
| `actionboard-devops-mission` | Run a maturity-gated DevOps mission — register actions, classify risk, score the five stages, enforce the formation gate |
| `mission-harness` | Build the sandbox harness for a mission — one isolated environment per agent |
| `openshell-admin` | Provision and govern OpenShell sandboxes, workspaces, and policies |
| `sandbox-up` / `sandbox-down` | Provision or tear down a sandbox for an agent or usecase |
| `sandbox-status` | Show sandboxes for a mission, tenant, or agent with phase and policy |
| `policy-widen` | Triage a denial and add the narrowest rule that fixes it |

## Browser actions in missions

The `browser-actions` skill (+ `kb/claude-browser-actions.md`) teaches ActionBoard V5 how to drive a
real browser during missions — navigate, read pages, fill forms, screenshot, debug web apps —
with hard rules: per-site approval, credentials and CAPTCHAs always handed to you,
confirmation before any irreversible web action, and page content treated as data, never as
instructions.

## Knowledge base

| Doc | Covers |
|-----|--------|
| [kb/mission-knowledge-format.md](kb/mission-knowledge-format.md) | schema.org JSON-LD envelope, identifier scheme, type mapping, status vocabulary, worked example |
| [kb/claude-browser-actions.md](kb/claude-browser-actions.md) | The two browser surfaces, capabilities, conduct rules |

## Tips

- For large codebases, run `/graphify` first so Green Agent's recon is graph-backed — reading
  one graph report costs a fraction of walking fifty source files.
- If Black Agent flags `needs-new-skill` gaps, it asks before scaffolding via `skill-creator`.
  New skills take effect on the next session or after `/reload-plugins`.
- Ask "what can the Agents do?" any time — the skills registry answers with the current map.

## Repository layout

The plugin lives at the repository root, so this repo is both the plugin and a
single-plugin marketplace pointing at itself (`"source": "./"`).

```
.claude-plugin/
  plugin.json         the plugin manifest
  marketplace.json    the marketplace manifest
commands/             /start-mission
agents/               black · green · blue · red · yellow + sandbox-warden
hooks/                PreToolUse/PostToolUse Bash guards for sandbox policy
skills/               mission-brief, mission-plan, mission-report,
                      skills-registry, browser-actions,
                      actionboard-devops-mission (scripts/, references/,
                      assets/, docs/),
                      mission-harness, openshell-admin (policies/, scripts/,
                      references/), sandbox-up, sandbox-down, sandbox-status,
                      policy-widen
kb/                   knowledge base the skills read at runtime
```

## License

MIT © Cloudscockpit
