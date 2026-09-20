# Troubleshooting

## Lifecycle phases

| Phase | Meaning | Action |
|---|---|---|
| Provisioning | Runtime setting up, or gateway waiting on the supervisor control session | Wait. `Ready=False` with `SupervisorNotConnected` is normal here. |
| Ready | Running, supervisor connected | Connect, exec, sync, expose |
| Stopping / Stopped | Compute released, record + persistent workspace retained | `sandbox start` to resume |
| Starting | Compute coming back; usable only after a fresh supervisor session | Wait for Ready |
| Error | Failed provisioning or execution | `openshell logs <name>` |
| Deleting | Tearing down, purging credentials | Nothing |

The compute backend can be ready before the supervisor connects, and a gateway
restart can bounce an existing sandbox back to `Provisioning`. Never report
Ready from the compute side alone — poll `sandbox get --output json`.

## Denial triage

`openshell logs <name> --tail --source sandbox`, or `openshell term` for the
live dashboard (Gateways / Providers / Sandboxes panels; `Tab` cycles).

| Signal | Cause | Fix |
|---|---|---|
| `action=deny` with host, port, binary | No matching endpoint **or** no matching binary in the same block | `policy update --add-endpoint host:port:access:protocol:enforce --binary <path>` |
| Denied with endpoint present | Method/path not in `rules` | `--add-allow 'host:port:METHOD:/path/**'` |
| `credential_endpoint_mismatch` | Policy allowed it; provider profile did not authorize the credential for that host/port/path | Fix the provider profile — `openshell provider profile export <id> -o yaml`. **Do not widen sandbox policy.** |
| `request_authority_mismatch` | HTTP authority differs from the authorized tunnel endpoint | Send `Host: api.example.com:8443` including the non-default port |
| WebSocket closed `1012` | Policy generation went stale on hot reload | Client reconnects; next request evaluated against current policy |

## Validation failures

`policy set` exit codes: `0` loaded, `1` validation failed, `124` timeout.
`FAILED_PRECONDITION` means an ambiguity failure — no revision was stored and
no profile update was partially applied.

Common rejections:

- Overlapping endpoints that disagree on TLS, destination, credential, parser,
  or enforcement settings.
- An update that adds a binary to an existing rule without declaring every
  endpoint and port that rule already authorizes (and the reverse). A rule
  authorizes every listed binary against every listed endpoint, so the gateway
  rejects the batch rather than granting a pair you did not ask for.
- Changing an endpoint's allow/deny rules without naming every port it carries.
- Targeting `--add-allow` / `--add-deny` at a host:port that appears in more
  than one rule — use full YAML replacement instead.
- An MCP endpoint sharing a host and port with a differently inspected
  endpoint, or two MCP endpoints disagreeing on strict-tool-name, method
  profile, or body limit.

To grant one binary access to only part of an existing rule's endpoints, pass
its own `--rule-name`; the gateway keeps your name whenever folding would grant
undeclared authorization.

A gateway preflight rejection never changes the active policy. If a candidate
reaches a supervisor and fails runtime validation, `policy_validation_failure_mode`
in `gateway.toml` under `[openshell.gateway]` decides: `fail_closed` (default)
publishes a quarantine generation and denies new egress until a valid policy
arrives; `retain_last_valid` keeps the previous valid generation active, but
still fails closed when there is none. Restart the gateway after changing it;
individual sandboxes cannot override it.

## Static section changes

`filesystem_policy`, `landlock`, and `process` are locked at creation. A hot
reload will not apply them. Recreate:

```bash
openshell sandbox download <name> output ./backup
openshell sandbox delete <name>
scripts/openshell-provision.sh --usecase <profile> --name <name> --policy ./new-policy.yaml
```

## Workspace access

- `openshell workspace list` returns no rows → the subject has no membership.
  Run `openshell whoami`, send `subject` to a Platform Admin.
- Membership correct but still denied → check `roles` and `scopes` in
  `openshell whoami --output json`. Scope enforcement needs the operation's
  scope; `openshell:all` satisfies everything.
- Only a Platform Admin assigns the `admin` membership role or runs `--global`
  operations. Local gateways without OIDC role config treat authenticated users
  as Platform Admins — do not assume a local success generalizes to the shared
  gateway.

## GPU

- `--gpu` with no count means `--gpu 1`. Kubernetes sets the `nvidia.com/gpu`
  limit; Docker and Podman select default NVIDIA CDI devices round-robin; VM
  gateways accept only one GPU.
- Enabling Docker CDI after the gateway started requires a gateway restart.
- Exact device selection: `--driver-config-json '{"docker":{"cdi_devices":["nvidia.com/gpu=0"]}}'`
  — the top-level key must match the active driver, IDs must be unique, and the
  list length must equal the GPU count.
- GPU passthrough is experimental. Expect rough edges; do not promise it in a
  customer-facing runbook without testing on that host.

## Transfers

`sandbox download` only accepts sources that resolve inside the sandbox's
canonical working directory — lexical escapes (`/etc/passwd`,
`/sandbox/../etc/passwd`) and symlink escapes are refused before any data
moves. Uploads respect `.gitignore` inside a Git repo; if filtering excludes
everything the CLI falls back to an unfiltered upload with a warning. Pass
`--no-git-ignore` deliberately, not reflexively.

Local directories and Dockerfiles in `--from` require a local gateway because
the CLI builds through the local Docker daemon. Use a registry reference for
remote gateways.
