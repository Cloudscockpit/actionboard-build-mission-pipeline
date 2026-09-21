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

## Remote sandboxes on an ActionBoard cloud pod

The gateway those sandboxes are created on can be on this machine or in the ActionBoard
cloud. The local path is unchanged and stays the default; the cloud path is a peer of it,
not a replacement. Three words that are easy to conflate: an ActionBoard **pod** is a
tenancy and billing label, the OpenShell **gateway** is the control plane that provisions
sandboxes, and a **workspace** is the isolation boundary inside that gateway. `--pod`
labels a sandbox; it never decides where the sandbox is created.

`/pod-connect` registers, authenticates, and selects a cloud gateway, then verifies the
identity the gateway actually sees. Three facts come from your ActionBoard pod console and
from nowhere else — no endpoint, no issuer, and no identity-pool default ships with this
plugin:

| Fact | Flag | Env |
|------|------|-----|
| Gateway URL (`https://…`) | `--url` | `ACTIONBOARD_GATEWAY_URL` |
| OIDC issuer | `--oidc-issuer` | `ACTIONBOARD_OIDC_ISSUER` |
| One-time token | *(none — by design)* | `ACTIONBOARD_POD_TOKEN` |

**The one-time token never goes on a command line.** argv is recorded by shell history, by
`ps`, and by this plugin's own audit hook, so a token placed there is already leaked. Prompt
for it instead — `read -rs` echoes nothing and puts no token text on the command line, so the
value never reaches `~/.zsh_history`. Paste at the silent prompt, then connect:

```bash
read -rs ACTIONBOARD_POD_TOKEN && export ACTIONBOARD_POD_TOKEN
```

```
/pod-connect https://<your-gateway> <pod-id>
```

Two alternatives that also keep the token off the command line. The clipboard one still leaves
the token in the pasteboard, so clear it afterwards:

```bash
export ACTIONBOARD_POD_TOKEN="$(pbpaste)"
```

```bash
<your password-manager read command> | \
  ${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-gateway-connect.sh \
    --url https://<your-gateway> --name actionboard-cloud \
    --oidc-issuer <your-issuer> --workspace <workspace> --pod <pod-id> \
    --token-stdin --dry-run
```

**What “not recorded” does and does not mean.** A bare `read` or `export` line contains no
`openshell` substring, so `hooks/audit-policy.sh` never matches it and nothing reaches
`.openshell-audit.log`. That is the whole claim — it is about this plugin's audit hook and
nothing else. Your shell still appends the line you typed to `~/.zsh_history` (or
`~/.bash_history`), so an `export ACTIONBOARD_POD_TOKEN=` with the token typed out after it
leaks it to history verbatim while the audit log stays clean. `read -rs` is what closes that
channel: the token is typed at the prompt, not on the command line. Do not inline-prefix the
wrapper either (`ACTIONBOARD_POD_TOKEN=… ./openshell-gateway-connect.sh …`) — that assignment
belongs to *your* command line, not the wrapper's, so the wrapper cannot redact it.
`--token-stdin` is immune to both channels — feed it from a vault or a variable, never from
a literal typed into the same command.

`--dry-run` runs first, every time: it registers nothing, authenticates nothing, and writes
nothing. Read the plan, then re-run without it. The wrapper finishes with `openshell whoami`
and `openshell workspace list` and reports the subject the gateway validated — a zero exit
code is not success, a validated subject with workspace membership is. A one-time token is
spent by the first successful connect, so a retry needs a fresh one from the pod console.

**Browser fallback.** If the pod issues no one-time tokens, add `--browser` and drop the
token; that runs the interactive `openshell gateway login` flow instead. It is the
documented fallback, not the normal path, and it cannot be used from a headless or CI shell.

Once connected, name the gateway on everything: `openshell-provision.sh --gateway <name>`,
and teardown's `--delete` refuses to infer it at all. The active selection is whatever the
last command left behind, which on a shared multi-tenant gateway is how work lands in
someone else's pod.

Two things that work locally fail against a remote gateway, and the provision wrapper exits
non-zero rather than letting them fail obscurely: an `--image ./dir` or Dockerfile build
(the CLI builds those on *this* machine's Docker daemon, which the gateway cannot see — push
and pass a registry reference), and a policy template still holding `REPLACE_` placeholders
(a warning locally, a hard stop remotely). The full list — images, GPU driver keys, port
forwards, editors, `policy set --global` — is the capability matrix in
[skills/openshell-admin/references/agent-profiles.md](skills/openshell-admin/references/agent-profiles.md)
under *Local vs remote/cloud gateway capability matrix*. It is not duplicated here.

The plugin's Bash hooks cover this path: the PreToolUse guard denies `--gateway-insecure`
and any credential-shaped value in argv, and asks before `--gateway-endpoint`,
`gateway remove`, and `gateway logout`; the PostToolUse hook redacts credential values before
appending to `.openshell-audit.log`. Neither of them takes effect from this repository —
the installed copy is what executes, so see
[Updating an installed plugin](#updating-an-installed-plugin) before relying on either.

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

### Updating an installed plugin

**Editing a clone of this repo does not change the plugin that runs.** Claude Code executes
the installed copies, not your working tree:

```
~/.claude/plugins/marketplaces/<marketplace>/
~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
```

`hooks/hooks.json` registers both Bash hooks as `${CLAUDE_PLUGIN_ROOT}/hooks/…`, and
`CLAUDE_PLUGIN_ROOT` resolves to that installed copy. This is not theoretical: while the
OpenShell hooks were being hardened, the old unpatched audit hook kept running from the
installed copy and kept writing unredacted command text to `.openshell-audit.log` long after
the repository copy was fixed.

So after any change here — and after any version bump — update or reinstall the plugin before
expecting it to take effect. Open `/plugin` and update the marketplace and the plugin, or
reinstall with the two Claude Code commands above. If the summary reports
`Run /reload-plugins to activate.`, run `/reload-plugins`.

**This one is security-relevant.** `hooks/guard-openshell.sh` is what denies a credential in
argv, and `hooks/audit-policy.sh` is what redacts one before it reaches the audit log. Until
the installed copy carries them, neither protection exists — whatever this repository says.

**Verify the reinstall actually took.** Both hook scripts declare a `HOOK_CONTRACT_VERSION`
constant, and the smoke suite asserts it against the `version` in
`.claude-plugin/plugin.json`. One command reads it back out of the copy that runs:

```bash
grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/marketplaces/*/hooks/*.sh
```

A correct result is one `HOOK_CONTRACT_VERSION="<version>"` line per hook script — two lines,
both equal to the version of the plugin you just installed. Anything else means the hardened
hooks are not the ones running:

- **No output at all** — the installed copy predates the constant. It is running pre-0.7.0
  hooks, so neither the PostToolUse redaction nor the PreToolUse argv-credential denial is in
  effect, and a token in argv will be written to the audit log in the clear.
- **A version older than the one in `.claude-plugin/plugin.json`** — the update did not take.
  Same exposure; the marketplace or the plugin is still pinned to the previous release.
- **One line instead of two** — only one of the two hooks was updated; the other protection
  is missing.

Re-run the update or the two install commands above until the grep matches, then
`/reload-plugins`. When several versions are on disk, the cache copy answers the same way:

```bash
grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/cache/*/*/*/hooks/*.sh
```

Fix this by reinstalling, never by hand-editing anything under `~/.claude/plugins/` — an
edited install is overwritten by the next update and silently diverges from this repository in
the meantime.

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
| remote-gateway-connect, remote-mission-execution | Black Agent | conditional — operator-supplied gateway URL, issuer, and one-time token; connect verified before the harness runs |

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
| `pod-connect` | Connect to a remote ActionBoard cloud OpenShell gateway with a one-time token, then verify the identity it sees |
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
                      references/), pod-connect, sandbox-up, sandbox-down,
                      sandbox-status, policy-widen
kb/                   knowledge base the skills read at runtime
```

## License

MIT © Cloudscockpit
