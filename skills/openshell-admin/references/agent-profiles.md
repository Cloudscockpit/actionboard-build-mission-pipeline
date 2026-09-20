# Usecase → Sandbox Profiles

Every profile is a starting point. Size up only with evidence (OOM, timeout);
never widen `access` without an observed denial.

## Profile table

| Usecase / Agent | Profile | Image | CPU | Memory | GPU | Policy template | Default access |
|---|---|---|---|---|---|---|---|
| Black — orchestration, mission brief, go/no-go | `orchestrator` | base | 2 | 4Gi | no | `orchestrator.yaml` | inference + gateway only |
| Green — data ingest, ETL, connectors | `data` | base | 4 | 8Gi | no | `data.yaml` | `read-only` REST on data sources |
| Blue — analysis, modeling, notebooks | `analysis` | base | 4 | 16Gi | optional | `analysis.yaml` | `read-only` + local inference |
| Red — action execution, writes to real systems | `action` | base | 2 | 4Gi | no | `action.yaml` | `read-write`, `enforce`, per-path allow |
| Yellow — defense, audit, policy review | `defense` | base | 2 | 4Gi | no | `defense.yaml` | `read-only`, `audit` enforcement |
| Model tuning / CAST runs | `train` | custom CUDA image | 8 | 64Gi | 1–8 | `train.yaml` | registry + object store only |
| Local inference server (Ollama, vLLM) | `inference` | `--from ollama` | 4 | 16Gi | 1 | `inference.yaml` | `inference.local` only |
| Untrusted code review / scratch | `scratch` | base | 2 | 4Gi | no | `scratch.yaml` | no egress at all |

## Per-Agent notes

**Black / orchestrator.** Holds the mission brief and dispatches. It must
reach the model endpoint and the pod control API and nothing else. It never
gets write access to a customer system — if the plan calls for a mutation, it
hands that step to Red. Give it `--no-keep` only for one-shot missions;
otherwise keep it alive for the mission duration so the ActionList context
survives.

**Green / data.** Needs package installs (`pip`, `uv`, `npm`) and read access
to sources. Bind the package endpoints to the package binaries specifically,
not to any binary. Uploads land through `--upload ./data:/workspace/data`,
which respects `.gitignore` by default. If ingest output must leave the
sandbox, use `sandbox download` rather than opening an egress path.

**Blue / analysis.** The memory-hungry one. GPU only when the analysis
actually runs a local model — a GPU request moves `/proc` to read-write in the
baseline filesystem policy, which is a real widening. Expose notebooks with
`service expose`, not by opening inbound network.

**Red / action.** The only Agent that mutates. Rules:
- `enforcement: enforce`, never `audit`.
- Every write path is an explicit `--add-allow` on a REST endpoint, e.g.
  `'api.github.com:443:POST:/repos/*/issues'`.
- Add a matching `--add-deny` for destructive subtrees (`/admin/**`,
  `delete*`, `*Destroy`) even when no allow rule currently reaches them.
- Credentials come from a provider with an endpoint-bound profile so a stolen
  placeholder cannot be replayed against another host.
- One sandbox per ActionList. Delete on completion; do not recycle.

**Yellow / defense.** Read-only everywhere, `enforcement: audit` so it can observe
what a policy *would* block without blocking the mission. It reads logs via
`openshell logs --source sandbox` and OCSF export, and it may propose policy
changes through Policy Advisor, but a human approves them from outside the
sandbox. Yellow never gets `policy set` rights.

**train.** Uses a custom CUDA image from your registry (`--from
registry.example.com/cast-tuning:tag`), `--gpu N`, and a large `--memory`.
Egress is limited to the model registry and object store. Long runs: expose
progress with `service expose`, and remember Kubernetes applies `--cpu`/
`--memory` as both request and limit.

**inference.** `--from ollama` with `--gpu 1`. Other sandboxes reach it through
`inference.local` routing rather than a direct network allow, which keeps
prompts off external endpoints and keeps keys at the gateway.

**scratch.** No `network_policies` at all. Use when running code you did not
write and do not trust. If it needs a package, install it in the image, not at
runtime.

## Label convention

Always set all four. They drive metering, forensics, and cleanup.

```
--label tenant=<tenant-slug>
--label pod=<pod-id>
--label agent=<black|green|blue|yellow|red>
--label mission=<mission-or-actionlist-id>
```

Query later with:

```bash
openshell sandbox list --selector tenant=acme,agent=yellow
openshell sandbox list --selector mission=mission-4471 -o json
```

Labels set at `create` are stored on the gateway object and returned on
`SandboxRef.labels`, so Python SDK-created sandboxes are found by the same
selectors.

## Workspace mapping

One workspace per tenant is the default. A workspace is the access boundary —
membership in one grants nothing in another, and only a Platform Admin creates
workspaces or assigns the `admin` role.

```bash
openshell workspace create --name tenant-acme
openshell workspace member add --workspace tenant-acme --subject '<oidc-subject>' --role admin
openshell workspace member add --workspace tenant-acme --subject '<oidc-subject>' --role user
```

Workspace Admin can manage providers, policies, settings, and add `user`
members in that workspace. Workspace User can create and use sandboxes and
services and read providers. Deleting a workspace requires it to be empty of
sandboxes, providers, profiles, services, SSH sessions, settings, policies,
draft chunks, and credential refresh state — and `default` cannot be deleted.
