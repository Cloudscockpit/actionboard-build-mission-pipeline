# Usecase → Sandbox Profiles

Every profile is a starting point. Size up only with evidence (OOM, timeout);
never widen `access` without an observed denial.

## Glossary — keep these four apart

The word "pod" means two unrelated things in this stack and mixing them
produces policies that look right and deny everything.

| Term | What it is | Where you see it |
|---|---|---|
| **ActionBoard pod** | A tenancy / billing label. Identifies whose usage this is. It is not a runtime, not a host, not a Kubernetes pod. | `--pod acme-prod`, `--label pod=<pod-id>`, pod ids like `pod-free-001`, URL paths like `/pods/<pod-id>/chat` |
| **OpenShell gateway** | The control plane the CLI authenticates to and that provisions sandboxes. May be local, remote-over-SSH, or hosted in the ActionBoard cloud. **Never call it a pod**, even when it is the "AI pod" gateway. | `openshell gateway add/select/login`, `-g/--gateway`, `OPENSHELL_GATEWAY_ENDPOINT` |
| **Workspace** | The isolation boundary *on* a gateway. Sandboxes, providers, policies, services, and inference routes live in exactly one and are invisible from another. Membership in one grants nothing in another. | `--workspace`, `OPENSHELL_WORKSPACE`, `openshell workspace list` |
| **Sandbox** | The data plane — the isolated environment an Agent actually runs in. Governed by a policy file. | `openshell sandbox create/exec/get` |

So: an Agent runs in a **sandbox**, inside a **workspace**, on a **gateway**,
billed to an ActionBoard **pod**. A sandbox policy governs sandbox egress; it
says nothing about which gateway provisioned it.

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

## Local vs remote/cloud gateway capability matrix

Most of the CLI behaves identically against a local gateway and against a
remote or ActionBoard-cloud gateway. The exceptions below are the ones that
silently waste a mission, because the flag is accepted and then the work does
not land where you expected.

| Capability | Local gateway | Remote / cloud gateway | Remedy on remote |
|---|---|---|---|
| `--from ./dir` | Works — CLI builds the directory's Dockerfile into the **local** Docker daemon | **Fails** — the built image exists only on your laptop; the remote gateway cannot see it | Build and push, then use a registry reference |
| `--from Dockerfile` | Works — same local-daemon build | **Fails** — same reason | `docker build && docker push`, then `--from <registry>/<img>:<tag>` |
| `--from base` (community name) | Works — resolves to `ghcr.io/nvidia/openshell-community/sandboxes/base:latest` | Works **if** the gateway's nodes can pull from ghcr.io | Registry-restricted cluster: mirror the image and set `OPENSHELL_COMMUNITY_REGISTRY` to the mirror prefix |
| `--from <registry-ref>` | Works | Works — this is the only portable image source | Private registry: the pull credential lives on the gateway side, not in your CLI config <sup>[i]</sup> |
| `--upload ./src:/workspace/src` | Works | Works — streamed through the gateway API, not the Docker daemon <sup>[i]</sup> | Nothing, but the bytes cross the WAN. `.gitignore` filtering happens locally; pass `--no-git-ignore` deliberately, not reflexively |
| `--forward [addr:]port` | Works | Works — tunneled through the gateway, and it holds the CLI session open | Long-lived exposure should be `service expose` instead; a forward dies with your session and with your gateway token <sup>[i]</sup> |
| `--editor vscode` / `cursor` | Works | Conditional — it installs an OpenShell-managed SSH config and needs the `ssh-proxy` path reachable through the edge <sup>[i]</sup> | If the edge does not pass SSH, drop to `sandbox exec` plus `service expose` |
| `service expose <sb> <port> <name>` | Works | Works, and it is the **preferred** remote answer — the URL is gateway-managed on the gateway's own domain and is subject to workspace auth | — |
| GPU via Docker CDI (`--driver-config-json '{"docker":{"cdi_devices":[…]}}'`) | Works on a Docker-driver gateway | **Fails** on a Kubernetes cloud gateway — `docker` is the wrong top-level key for the active driver | Use the Kubernetes key: `--driver-config-json '{"kubernetes":{"pod":{"node_selector":{"pool":"gpu"}}}}'`. Note that *enabling* Docker CDI after a gateway has started requires a gateway restart, which on a shared gateway is a Platform Admin action you cannot self-serve |
| GPU on Kubernetes (`--gpu N`) | Only if the local gateway runs the Kubernetes driver | Works when a GPU node pool exists; sets the `nvidia.com/gpu` limit, and `--cpu`/`--memory` apply as both request and limit | Select the pool with the `kubernetes` driver-config key above. VM gateways accept exactly one GPU. GPU passthrough is experimental — test before promising it |
| `sandbox download` | Works | Works — sources must still resolve inside the sandbox's canonical workdir; lexical and symlink escapes are refused before any data moves | — |
| `policy set --global` | Affects only your own gateway | Affects **every workspace on the shared gateway**, and while a global policy exists all sandbox-level policy updates are rejected | Do not run it on a shared cloud gateway. It is a Platform Admin decision, not a mission step |

<sup>[i]</sup> INFERRED from CLI help text and the local/remote split, not
confirmed against a live ActionBoard cloud gateway. Verify on first contact
and correct this table.

The short version: on a remote or cloud gateway, **images must come from a
registry and GPU selection must use the Kubernetes driver key**. Everything
else degrades gracefully.

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

On a laptop-local gateway you can get away with dropping labels; nobody else
is on it. On a shared ActionBoard cloud gateway they stop being optional. The
gateway is multi-tenant, so `tenant` and `pod` are the only things that
attribute cost and forensics to the right customer, and `agent` plus `mission`
are the only way to tell your sandboxes from another operator's in the same
workspace. A cloud sandbox created without the four labels is an unattributable
line item — treat a missing label as a provisioning error, not a style nit.
Remember `pod` here is the ActionBoard tenancy pod, not the gateway.

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
