---
name: pod-connect
description: Connect this machine to a remote ActionBoard cloud OpenShell gateway (an AI pod) with a one-time token, verify the identity the gateway actually sees, and hand off to provisioning. Use before running a mission against cloud compute instead of a local gateway.
argument-hint: "<gateway-url> [pod-id] — e.g. https://gw.pod-4471.actionboard.example acme-prod"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-gateway-connect.sh *) Bash(openshell whoami *) Bash(openshell gateway list *) Bash(openshell gateway info *) Bash(openshell workspace list *)
---

# Connect an ActionBoard pod

Target: **$ARGUMENTS**

A **pod** is the ActionBoard tenancy and billing label. A **gateway** is the
OpenShell control plane. A **workspace** is the isolation boundary inside that
gateway. They are three different things and conflating them is how a mission
lands in the wrong tenant. `--pod` is a label on the sandbox; it never selects
where the sandbox is created.

## Never put the token on the command line

The one-time token is a secret. argv is recorded by the shell, by `ps`, and by
this plugin's own `hooks/audit-policy.sh`. The wrapper has no `--token` flag and
refuses to start if it sees a token-shaped value in argv.

**Prefer `read -rs`.** It echoes nothing to the screen and writes nothing to
shell history, so the token exists only in the variable:

```bash
read -rs ACTIONBOARD_POD_TOKEN && export ACTIONBOARD_POD_TOKEN
```

Two alternatives, in order of preference:

```bash
export ACTIONBOARD_POD_TOKEN="$(pbpaste)"                # token stays off the line
<pw-cli> show <item> | … --token-stdin                   # straight from a vault
```

Do **not** type the token as a literal:

```bash
export ACTIONBOARD_POD_TOKEN='<literal token>'   # goes into ~/.zsh_history verbatim
```

### Do not inline-prefix the wrapper

```bash
ACTIONBOARD_POD_TOKEN=xyz .../openshell-gateway-connect.sh --url …   # WRONG
```

That assignment belongs to the caller's command line, not to the wrapper, so
the wrapper cannot redact it, and `hooks/audit-policy.sh` may write it verbatim
into `.openshell-audit.log` — the 0.6.1 hook does, because the wrapper's path
contains `openshell`; the 0.7.0 hook redacts it. Whichever version is
*installed* under `~/.claude/plugins` is the one that runs, so assume the
leaking one until you have reinstalled.

### What "not recorded" does and does not mean

A bare `export` on its own line is not recorded **by this plugin's audit hook**
— it contains no `openshell` substring, so the hook never matches it. That is
the only claim being made. Your **shell** still records it: a literal token
typed at an interactive prompt lands in `~/.zsh_history` verbatim, which is the
same argv-in-history leak channel named above. `read -rs` is what closes it;
`--token-stdin` is immune to both.

## Procedure

1. **Collect the connection facts.** From the ActionBoard pod console, the
   operator needs the gateway URL, the OIDC issuer, and a freshly minted
   one-time token. Nothing is hardcoded here and no issuer ships as a default —
   ask rather than guess, and never reuse an issuer from a policy file.

   | Fact | Flag | Env |
   |---|---|---|
   | Gateway URL (`https://…`) | `--url` | `ACTIONBOARD_GATEWAY_URL` |
   | OIDC issuer | `--oidc-issuer` | `ACTIONBOARD_OIDC_ISSUER` |
   | Client id / audience / scopes | `--oidc-client-id` `--oidc-audience` `--oidc-scopes` | `ACTIONBOARD_OIDC_*` |
   | Local gateway name | `--name` | `ACTIONBOARD_GATEWAY_NAME` |
   | Workspace | `--workspace` | `OPENSHELL_WORKSPACE` |
   | Pod (tenancy label) | `--pod` | `ACTIONBOARD_POD_ID` |
   | One-time token | *(none — by design)* | `ACTIONBOARD_POD_TOKEN` |

   An `http://` URL is refused: it registers a plaintext gateway that skips both
   mTLS and browser authentication. A cloud pod is always `https://`.

2. **Show the plan.** Run with `--dry-run` first, as every skill here does, and
   surface the resolved gateway name, endpoint, issuer, audience, scopes,
   workspace, and pod. The token renders as `****`. Wait for the user to confirm.

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-gateway-connect.sh \
     --url <https://gateway> --name actionboard-cloud \
     --oidc-issuer <issuer> --oidc-audience <audience> --oidc-scopes "<scopes>" \
     --workspace "${OPENSHELL_WORKSPACE:-default}" --pod <pod-id> \
     --dry-run
   ```

   `--dry-run` registers nothing, authenticates nothing, and writes nothing
   under `~/.config/openshell`.

3. **Connect.** Re-run without `--dry-run`. The wrapper registers the gateway
   non-interactively, completes the headless OIDC exchange with the one-time
   token, and selects the gateway.

4. **Verify the identity the gateway sees.** The wrapper does this and prints it;
   do not assert success from a zero exit code alone.

   ```bash
   openshell whoami --output json
   openshell workspace list
   ```

   Empty workspace rows mean the subject has no membership. Report the `subject`
   verbatim and stop; only a Platform Admin can grant it.

5. **Hand off.** Return only: gateway name, endpoint, auth mode, pod, workspace,
   subject, provider, roles, scopes, and the next command. Then continue with
   `/sandbox-up` for a single sandbox, or `/mission-harness` for a full
   formation. Pass `--gateway <name>` to the provision wrapper so the harness
   cannot drift onto whichever gateway happens to be active.

## When it fails

**The identity provider rejected the credential.** The wrapper reports this as
its own distinct error rather than a generic auth failure, because it is the
failure you will actually hit — but it does not claim to know the cause.
Cognito answers `invalid_client` to all four of: token already used, token
expired, token never valid for this issuer/client/audience, and the one-time
token not being an OAuth2 client secret at all. The first remedy is a fresh
token from the pod console plus `openshell gateway remove <name>`. If a second,
freshly minted token fails identically, stop burning tokens — the mechanism is
the suspect, so retry with `--browser`.

**Browser fallback.** If the headless path is unavailable — the pod issues no
one-time tokens, or the client is not configured for it — add `--browser` and
drop the token. This opens the identity provider's login page and is the
documented fallback, not the normal path. It cannot be used from a headless or
CI shell.

**Version drift.** The wrapper is built against `openshell 0.0.110` and warns,
without failing, on any other version. If it warns, re-verify the gateway flags
before trusting the result — say so plainly rather than proceeding quietly.

## After connecting

Against a remote gateway, two things that work locally stop working, and
`openshell-provision.sh` refuses them rather than letting them fail obscurely:

- `--image ./dir` and Dockerfile builds. The CLI builds those on **this**
  machine's Docker daemon, which the pod cannot see. Push the image and pass a
  registry reference.
- A policy template still holding `REPLACE_` placeholders. On a local gateway
  that is a warning; against a pod it is a hard stop, because a sandbox that
  looks ready and can reach nothing is worse on shared compute than no sandbox.

Disconnect with `openshell gateway logout <name>`; remove the registration
entirely with `openshell gateway remove <name>`.
