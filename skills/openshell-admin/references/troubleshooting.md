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

On a remote or cloud gateway, `Provisioning` also covers an image pull on the
gateway's own nodes. A stall there is usually a registry problem — an image
reference the cluster cannot resolve, or a private registry with no pull
credential on the gateway side — not a supervisor problem. Check
`openshell logs <name>` before waiting any longer, and remember that an image
you built locally with `--from ./dir` does not exist on that cluster at all.
(Registry/pull-credential attribution is INFERRED from the local/remote split;
confirm against the gateway's own events on first contact.)

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
| 401/403 from the `openshell` CLI itself, or `whoami` returns no identity | Not a sandbox denial at all — the CLI is not authenticated to the gateway | See **Gateway auth failures** below. Do not touch sandbox policy; it is not the problem |
| Same policy passes locally, denies on the cloud gateway | A `--global` policy on the shared gateway, or a provider profile that exists only in your local workspace | `openshell settings get <name>` shows policy source and revision. Check the provider exists in the *target* workspace — resources are invisible across workspaces |

## Gateway auth failures

Everything below is about reaching the **gateway**. It is a different failure
class from the denial triage above, which is about a sandbox reaching the
internet. If `openshell whoami` does not return an identity, no amount of
policy work will help — you are not authenticated yet.

**The remedy for a failing `whoami` is `gateway login`, never another
`whoami`.** `whoami` reports the identity the *gateway* validated; the CLI
does not infer it locally, so re-running it returns the same error forever.

Which login applies depends on how the gateway was registered. Check first:

```bash
openshell gateway list
openshell gateway info <name>        # name, endpoint, is_remote, port, auth_mode
openshell status --output json       # gateway reachability
```

| Auth mode | Registered as | Typical symptom | Remedy |
|---|---|---|---|
| **mTLS (local)** | `gateway add https://… --local` | Connection refused or TLS handshake failure | Certificates must **already exist** at `~/.config/openshell/gateways/<name>/mtls/{ca.crt,tls.crt,tls.key}`. `gateway add` does not mint them and `gateway login` does not fix them. Get them from whoever runs the gateway. |
| **mTLS (remote)** | `gateway add https://… --remote <ssh-dest>`, or an `ssh://user@host:port` endpoint | SSH failure, or TLS handshake failure after SSH succeeds | Two hops: fix SSH reachability first (`ssh <ssh-dest>`), then the same cert triple as above. `gateway login` is not involved. |
| **OIDC** | `gateway add https://… --oidc-issuer <URL>` (plus `--oidc-client-id`, default `openshell-cli`; `--oidc-audience`; `--oidc-scopes`) | 401, or `whoami` returns nothing; token at `~/.config/openshell/gateways/<name>/oidc_token.json` is missing or expired | `openshell gateway login <name>` — opens a browser. To switch users, `gateway logout` first: after a logout the browser flow requests a fresh identity-provider prompt. If login succeeds but operations are denied, the problem is scopes, not auth — see Workspace access. |
| **Edge JWT** | `gateway add https://…` with **no** extra flags — an `https://` endpoint with nothing else is treated as an edge-authenticated (cloud) gateway | 401/403 from the edge; token at `~/.config/openshell/gateways/<name>/edge_token` is missing or expired | Default path: `/pod-connect` with a one-time token (unattended). Fallback: `openshell gateway login <name>`, which opens a browser for the edge proxy's login flow. |
| **Plaintext** | `gateway add http://…` — plaintext, skips both mTLS client-certificate lookup and browser authentication | Connection refused / timeout | There is nothing to authenticate. This is a connectivity problem: wrong host, wrong port, gateway not running. Do not "fix" it by adding `--gateway-insecure`, and never register a gateway you reach over a network as `http://`. |

`--gateway-insecure` skips TLS **verification**, not authentication. It is a
debugging flag for a self-signed local gateway. Using it against a cloud
gateway turns a trust failure into a silent MITM window — if you reach for it,
stop and fix the CA instead.

### Which of the four auth paths you are on

The v0.0.110 binary implements four ways to reach a remote gateway, and only
one of them works without a browser. Identifiers below are verbatim from
`strings $(command -v openshell)` and `gateway login --help`; nothing here was
measured against a live identity provider.

| Path | Unattended? | How to tell you are on it |
|---|---|---|
| Cloudflare Access edge auth | no — browser | `edge_team_domain` / `edge_auth_url` on the gateway; request carries `CF_Authorization`; token cached at `gateways/<name>/edge_token` |
| OIDC authorization code + PKCE | no — browser | `code_verifier` in the exchange; result in `gateways/<name>/oidc_token.json` |
| OIDC device authorization grant | no — needs a browser somewhere | grant type `urn:ietf:params:oauth:grant-type:device_code`; prints a `user_code` and a `verification_uri`, then logs `Device authorization pending, continuing to poll` until `Device code expired. Please try again.` or `Authorization was denied by the user or administrator` |
| OIDC client credentials | **yes — the only headless path** | driven by `OPENSHELL_OIDC_CLIENT_SECRET`; this is the path `/pod-connect` uses |

Of the twenty `OPENSHELL_*` environment variables the binary reads, exactly
one is a credential: `OPENSHELL_OIDC_CLIENT_SECRET`. There is no
`OPENSHELL_TOKEN`, no `OPENSHELL_EDGE_TOKEN` and no `OPENSHELL_ACCESS_TOKEN`,
and nothing in the binary matches enrol / enrollment / activation / redeem /
one-time / single-use. No path accepts an operator-supplied single-use token
as direct input.

**`The OIDC provider does not advertise a device_authorization_endpoint.
Enable the device authorization grant on this client, or use client
credentials for headless automation.`** — a real message, and a likely one.
Read it as: the CLI does support the device grant and reached for it (it tries
that path under `OPENSHELL_NO_BROWSER`), but this identity provider does not
publish a `device_authorization_endpoint`, so the device path is unavailable
and client credentials is the only headless option left. It is not a mistake
in your invocation and no flag suppresses it. Either ask the IdP admin to
enable the device authorization grant for this client, or stay on client
credentials. Expect this message on an AWS Cognito user pool, which does not
implement RFC 8628 — **not verified here**: this repository did not contact
Cognito, so carry that as a known limitation reported upstream, not as
something measured.

**The semantic gap, stated plainly.** An OAuth2 client secret is a long-lived
credential belonging to a client; a single-use activation code is a different
kind of object. `/pod-connect` maps the operator's one-time token onto
`OPENSHELL_OIDC_CLIENT_SECRET`, which is correct only if what the ActionBoard
pod console issues is usable as a client secret for the configured client id.
If it is a genuine single-use code, v0.0.110 has no slot for it at all and the
first real connect fails with `invalid_client` — cause four in *One-time token
rejected* immediately below. Which kind of credential the pod issues is an
open question for the ActionBoard pod owners, not something to work around
here: there is no flag that would.

### One-time token rejected (consumed, expired, or not a client secret)

This is its own error, not a generic auth failure, and it is the single most
likely way the remote path fails on a second attempt.

Symptoms: `/pod-connect` (or the edge login) rejects a token that the operator
just handed you; or a connect that worked once fails when re-run; or the
gateway was registered but `whoami` returns 401 immediately afterwards.

Remedy when this really is a stale token, in this order:

1. **Do not retry the same token.** A one-time token is one-time. Retrying
   burns time and produces an identical error.
2. Ask the operator for a **fresh one-time token from the ActionBoard pod
   console**. Say explicitly that the previous one is spent — otherwise you
   will be handed the same string again.
3. Re-run `/pod-connect` with the new token, then `openshell whoami` to
   confirm the gateway validated an identity.

The identity provider does not tell you **which** of four causes it was. An
AWS Cognito user pool answers `invalid_client` to all four:

1. the token was already used to connect, from this machine or another one;
2. the token passed its expiry window;
3. the token was never valid for this issuer / client id / audience;
4. **the ActionBoard one-time token is not an OAuth2 client secret at all** —
   in which case client credentials is the wrong mechanism for this pod and no
   fresh token will ever work. The wrapper presents the token as the secret in
   a client-credentials exchange, and the header of
   `scripts/openshell-gateway-connect.sh` marks that mapping `INFERRED`, not
   proven against this pod.

Only the first two are fixed by a fresh token, and they are indistinguishable
from each other — do not spend time separating them. **A fresh token does not
fix causes three and four**, so a second, freshly minted token that fails
identically is the signal to stop re-minting and change mechanism: re-run the
wrapper with `--browser` and no token, which runs the interactive
`openshell gateway login` flow instead of the headless client-credentials
exchange. It needs a browser and cannot be used from a headless or CI shell.
If `--browser` authenticates where the headless path did not, the one-time
token is not a client secret for this pod: say so plainly and ask the operator
which mechanism the pod actually issues tokens for, rather than looping on
fresh tokens. Cause three is settled the same way — by re-checking the issuer,
client id and audience against the pod console, not by another token.

Report it to the operator as "one-time token rejected (consumed, expired, or
not a client secret for this pod)" rather than guessing which.

If a fresh token also fails immediately and `--browser` is not available,
check the clock skew on the machine and the endpoint URL you registered before
escalating.

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

**On a shared cloud gateway, treat that last point as the default case, not an
edge case.** A local gateway with no OIDC role configuration hands every
authenticated user Platform Admin, so *everything* works on your laptop: you
create workspaces, set global policy, add members. None of that transfers. The
same command against the shared ActionBoard cloud gateway runs as whatever
roles and scopes the identity provider actually issued, which is usually
`user` in one workspace. A local dry run proves your YAML parses. It proves
nothing about your authority.

Empty `workspace list` on a cloud gateway — the exact sequence:

```bash
openshell whoami --output json      # copy the "subject" value verbatim
openshell workspace list            # no rows = no membership anywhere
```

1. Report the `subject` string, the gateway name, and the workspace you need.
2. Wait for a Platform Admin to run `workspace member add`. Only they can.
3. **Do not proceed by provisioning into `default`.** `default` on a shared
   gateway is somebody else's blast radius, it is the one workspace that
   cannot be deleted, and a sandbox you leave there is unattributable. A
   blocked mission is a smaller problem than a mission that ran in the wrong
   tenant's workspace.

Membership present but operations still denied is a **scope** problem, not a
membership problem: re-read `roles` and `scopes` from
`openshell whoami --output json`. Scope enforcement requires the operation's
own scope; `openshell:all` satisfies all scoped methods. Ask for the missing
scope by name.

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
remote gateways. This is not a warning you can ignore: the build
succeeds, the image lands on your laptop, and the remote gateway then fails to
find it. The full local-vs-remote list is the capability matrix in
`references/agent-profiles.md`.
