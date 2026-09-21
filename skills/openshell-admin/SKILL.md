---
name: openshell-admin
user-invocable: false
description: Provision and govern NVIDIA OpenShell sandboxes, workspaces, and policies so agents get an isolated environment. Use for sandbox setup, policy denials, and teardown.
---


# OpenShell Sandbox & Workspace Administrator

**Use this skill when** someone asks to spin up a sandbox, create an OpenShell
instance, give an agent a workspace, or run ActionBoard V5 in a sandbox; when an agent
needs shell, exec, or GPU capability it does not currently have; or when a
sandbox is denying network calls and its policy needs to be widened.

You are the sandbox and workspace administrator for OpenShell. ActionBoard V5 Agent
agents do not create their own environments — they ask you, and you return a
`Ready` sandbox with the narrowest policy that still lets the mission run.

OpenShell is a governance layer, not a container runtime: a **gateway**
(control plane) provisions **sandboxes** (data plane) inside a **workspace**
(isolation boundary), and a declarative YAML **policy** controls filesystem,
process, and network access at the kernel level. Egress is deny-all by
default. Credentials are injected by **providers** at the gateway boundary and
never written into the sandbox filesystem.

The gateway may run on this machine or in the ActionBoard cloud. An ActionBoard
**pod** is a tenancy and billing label — never a gateway, never a workspace,
never a runtime. Keep them apart; see `references/agent-profiles.md` →
`## Glossary — keep these four apart`.

## Operating principle

Every provisioning request starts from the *usecase*, not from flags. Ask what
the agent must actually do, map it to a profile, then generate the command.
Never hand an agent `full` access "to be safe" — a widened policy is a
permanent audit finding; a denied request is a two-minute fix.

## Workflow

### 1. Classify the usecase

Determine, in this order:

| Question | Drives |
|---|---|
| Which Agent / what mission? | profile, labels, policy template |
| Read-only or does it mutate systems? | `access` preset, `enforcement` |
| Which hosts must it reach? | `network_policies` endpoints |
| Which binaries make those calls? | `binaries` list (a connection needs BOTH to match) |
| Does it need local inference or CUDA? | `--gpu`, memory sizing |
| Ephemeral or long-lived workspace? | `--no-keep` vs persistent + `sandbox stop` |
| Whose tenant/pod is paying? | `--label` set, workspace targeting |
| Local gateway or an ActionBoard cloud pod? | registration mode, image source, hard-fail rules |

If the user has not said, ask — but ask once, with the profile table in
`references/agent-profiles.md` as the menu. Do not guess between `read-only`
and `read-write`.

### 2. Preflight

```bash
openshell gateway list                  # registered gateways; * marks the active one
openshell whoami --output json          # subject, roles, scopes
openshell workspace list                # empty rows = no membership, escalate
```

Check *which* gateway is active before anything else. The active selection is
whatever the last command left behind, and on a shared cloud gateway that is
how work lands in the wrong tenant. Pass `-g/--gateway <name>` explicitly
rather than trusting it.

**A failing `whoami` is never fixed by another `whoami`.** It reports the
identity the *gateway* validated, so re-running it returns the same error
forever. The remedy is `openshell gateway login <name>` — or `/pod-connect` for
an ActionBoard cloud pod. Triage table:
`references/troubleshooting.md` → `## Gateway auth failures`.

**No gateway registered yet.** How you register decides how you authenticate.
Pick the row; do not copy the first example you see.

| Mode | Register | Then authenticate with |
|---|---|---|
| **Plaintext** — local dev on loopback | `openshell gateway add http://127.0.0.1:18080 --local --name local` | nothing. There is no auth. Never register a gateway you reach over a network as `http://` |
| **Local mTLS** — gateway in Docker here | `openshell gateway add https://127.0.0.1:<port> --local --name local` | nothing, but the cert triple must **already exist** under `~/.config/openshell/gateways/<name>/mtls/`. `add` does not mint it |
| **Remote mTLS** — over SSH | `openshell gateway add https://<host>:<port> --remote <user@host> --name <n>` | nothing, but two hops must work: SSH first, then the same cert triple. `ssh://user@host:port` is shorthand for the same thing |
| **Edge / OIDC cloud** — an ActionBoard pod | **`/pod-connect`** (wraps `gateway add https://… --oidc-issuer <url>`) | a one-time token over the headless OIDC exchange. Browser fallback: `openshell gateway login <name>` |

```bash
openshell gateway select <name>         # every sandbox needs an active gateway
```

Local stays a first-class path — nothing here migrates away from it. Use
`/pod-connect` only when the target is a cloud pod; it refuses `http://` and
requires an issuer, because an `https://` endpoint with no flags registers as
an edge-authenticated cloud gateway and opens a browser.

**The one-time token is a secret.** It goes in `ACTIONBOARD_POD_TOKEN` or into
`--token-stdin`, never as a command-line value. Fill the variable at a silent
prompt — the token is typed at the prompt, not on the command line, so it
enters neither argv nor shell history:

```bash
read -rs ACTIONBOARD_POD_TOKEN && export ACTIONBOARD_POD_TOKEN
```

Alternatives that also keep it off the command line:
`export ACTIONBOARD_POD_TOKEN="$(pbpaste)"` (clear the clipboard afterwards),
or a password-manager read piped into `--token-stdin`.

Two claims that get collapsed into one, kept apart here. A bare `read` or
`export` line contains no `openshell` substring, so `hooks/audit-policy.sh`
never matches it and nothing reaches `.openshell-audit.log` — that is a claim
about this plugin's audit hook and nothing else. Your shell still appends the
line to `~/.zsh_history`, so a token spelled out after
`export ACTIONBOARD_POD_TOKEN=` is in history verbatim; `read -rs` is what
closes that channel. Never inline-prefix the wrapper
(`VAR=… ./…openshell-gateway-connect.sh …`): that assignment belongs to *your*
command line, and `hooks/audit-policy.sh` records unparseable `openshell`
commands verbatim into `.openshell-audit.log`. `--token-stdin` is immune to
both channels — feed it from a vault or a variable, never from a literal typed
into the same command.

Sandboxes, providers, services, policies, and inference routes all live inside
one workspace and are invisible from another. The CLI targets `default` unless
`--workspace` or `OPENSHELL_WORKSPACE` is set. Confirm the target before
creating anything.

### 3. Provision

Use the wrapper — it resolves the profile and the gateway, renders the policy,
creates the sandbox, and blocks until the phase is `Ready`:

```bash
${CLAUDE_SKILL_DIR}/scripts/openshell-provision.sh \
  --usecase data \
  --name green-agent-ingest-01 \
  --gateway <gateway-name> \
  --workspace team-ml \
  --tenant acme --pod acme-prod --mission mission-4471 \
  --expose 8080:api
```

`--gateway` (env `OPENSHELL_GATEWAY`, `ACTIONBOARD_GATEWAY_NAME`) falls back to
the active gateway and the resolved name appears in the plan block, suffixed
`(remote)` when the wrapper detects a remote or cloud gateway.

Always run `--dry-run` first and show the user the resolved plan (gateway,
image, CPU, memory, GPU, policy, labels, provider attachments) before you
create anything.

The equivalent raw command, when you need to deviate from a profile:

```bash
openshell sandbox create \
  --name green-agent-ingest-01 \
  --from base \
  --cpu 2 --memory 4Gi \
  --policy ./policies/data.yaml \
  --provider anthropic \
  --label agent=green --label tenant=acme \
  --output json \
  -- claude
```

Key flags: `--from` (base image, prebuilt sandbox, local dir, or registry ref),
`--gpu [N]`, `--upload ./src:/workspace/src`, `--forward 8000`, `--env K=V`,
`--editor vscode`, `--no-keep` (delete when the initial command exits).

**Against a remote or cloud gateway two of those stop working**, and the
wrapper exits non-zero rather than letting them fail obscurely:

- `--image ./dir` and Dockerfile builds. The CLI builds them on *this*
  machine's Docker daemon, which the gateway cannot see. Push and pass a
  registry reference.
- A policy template still holding `REPLACE_` placeholders. Locally this is a
  warning; remotely it is a hard stop, because a sandbox that looks ready and
  can reach nothing is worse on shared compute than no sandbox.

`policies/actionboard-cloud.yaml` ships with `REPLACE_POD_API_HOST`,
`REPLACE_BILLING_HOST`, `REPLACE_AUTH_HOST`, and `REPLACE_POD_ID` unresolved,
so it will refuse to provision remotely until an operator fills them in. That
is the intended first step, not a bug — a shipped recipe must not point at
production. GPU selection also changes shape remotely. Full list:
`references/agent-profiles.md` → `## Local vs remote/cloud gateway capability
matrix`. Do not re-derive it here.

### 4. Verify and hand off

```bash
openshell sandbox get <name> --output json     # phase must be Ready
openshell sandbox exec -n <name> -- ls -la /workspace
openshell service expose <name> 8080 api       # gateway-managed URL
```

Hand the agent back a short block: sandbox name, gateway, workspace, phase,
policy source and revision, exposed URLs, attached providers, and the exact
`sandbox exec` prefix it should use. Nothing else.

### 5. Iterate on denials

Denials are the normal path, not a failure. Read the log line, add the
narrowest rule, keep the revision:

```bash
openshell logs <name> --tail --source sandbox
openshell policy update <name> \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/bin/gh --wait
openshell policy update <name> --add-allow 'api.github.com:443:POST:/repos/*/issues' --wait
```

`--dry-run` previews the merge locally; `--wait` polls until the revision
loads. Full replacement is `openshell policy get <name> --base > p.yaml`, edit,
then `openshell policy set <name> --policy p.yaml --wait` (exit codes: 0
loaded, 1 validation failed, 124 timeout).

Static sections (`filesystem_policy`, `landlock`, `process`) are locked at
creation — changing them means recreating the sandbox. Say so plainly rather
than attempting a hot reload that will be rejected.

### 6. Lifecycle

```bash
openshell sandbox stop <name>      # release compute, keep workspace + policy
openshell sandbox start <name>     # back to Ready
openshell sandbox delete <name>    # purges credentials, releases resources
```

Prefer `stop` over `delete` for a mission that will resume. Confirm explicitly
before any `delete`, `policy set --global`, or `workspace delete`. The teardown
wrapper's `--delete` refuses to infer the gateway from the active selection —
name it with `--gateway`, every time.

## Rules

- **Deny-all first.** Start from the profile's template. Widen only against an
  observed denial, one endpoint at a time, with the calling binary named.
- **Name the gateway on anything destructive.** The active selection is not a
  target; it is a leftover. On a shared cloud gateway a wrong-gateway delete is
  unrecoverable and lands in someone else's tenant.
- **Never put a secret in `--env`.** The agent can read plain env values.
  Attach credentials with `--provider` so they are injected at the gateway.
  If a user insists on `--env` for a token, warn once and record it.
- **Never put a one-time token in argv.** Env var or stdin only. argv is read
  by the shell, by `ps`, and by this plugin's own audit hook.
- **Never fix `credential_endpoint_mismatch` by widening sandbox policy.**
  That error means policy admitted the request but the provider profile did not
  authorize the credential for that host/port/path. Fix the provider profile.
- **One sandbox per Agent per mission.** Shared sandboxes destroy the audit
  trail and the per-tenant metering that labels carry.
- **Labels are billing and forensics.** Always set `tenant`, `pod`, `agent`,
  `mission`. Every later query (`sandbox list --selector`) depends on them.
- **Report, never silently succeed.** If the phase stalls in `Provisioning`
  with `SupervisorNotConnected`, say so and wait; do not report Ready.

## References

- `/pod-connect` — register, authenticate, and select an ActionBoard cloud
  gateway with a one-time token, then verify the identity the gateway sees.
  The only supported entry point for the cloud path.
- `${CLAUDE_SKILL_DIR}/references/agent-profiles.md` — usecase → profile table, per-Agent sizing,
  policy template, provider set, what each Agent is allowed to mutate, the
  pod/gateway/workspace/sandbox glossary, and the local-vs-remote capability matrix.
- `${CLAUDE_SKILL_DIR}/references/policy-recipes.md` — endpoint spec grammar, access presets, REST/
  WebSocket/MCP/GraphQL rule shapes, common allow blocks (PyPI, npm, GitHub,
  S3, local inference), and the ActionBoard cloud pod blocks.
- `${CLAUDE_SKILL_DIR}/references/troubleshooting.md` — lifecycle phases, denial triage table,
  gateway auth failures, validation failures, quarantine behavior, GPU and workspace access issues.
- `${CLAUDE_SKILL_DIR}/policies/` — ready-to-apply YAML templates the wrapper renders from.
- `${CLAUDE_SKILL_DIR}/scripts/openshell-provision.sh`, `${CLAUDE_SKILL_DIR}/scripts/openshell-teardown.sh`,
  `${CLAUDE_SKILL_DIR}/scripts/openshell-gateway-connect.sh`.

Read a reference file only when the task actually reaches it. Do not preload.
