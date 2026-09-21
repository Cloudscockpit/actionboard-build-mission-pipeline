---
name: sandbox-status
description: Show OpenShell sandboxes for a mission, tenant, or Agent, with phase, policy revision, and recent denials. Use to check whether an agent environment is ready or being blocked.
argument-hint: "[selector or sandbox name] [-g <gateway>] — e.g. mission=m-4471"
allowed-tools: Bash(openshell sandbox list *) Bash(openshell sandbox get *) Bash(openshell logs *) Bash(openshell service list *) Bash(openshell settings get *) Bash(openshell gateway list *)
---

# Sandbox status

Target: **$ARGUMENTS**

If the argument looks like `k=v`, treat it as a label selector; otherwise treat it
as a sandbox name. With no argument, list everything in the current workspace.

**Resolve the gateway before reading anything.** Status read from the wrong
control plane is worse than no status: it looks authoritative and describes
somebody else's sandboxes. Pass `-g/--gateway <name>` (env `OPENSHELL_GATEWAY`)
on every call. If the user did not name one, resolve and state which is active:

```bash
openshell gateway list                         # * marks the active one
```

```bash
openshell sandbox list -g <gateway> --selector "$ARGUMENTS" -o json
openshell sandbox get <name> -g <gateway> --output json
openshell logs <name> -g <gateway> --source sandbox --since 30m --level warn
openshell service list <name> -g <gateway>
```

Report as a compact table: **gateway**, name, agent, phase, policy source and
revision, exposed services. Name the gateway even when it is the active one —
the whole point is that the reader can tell. Then, separately, any `action=deny`
lines from the last window grouped by host and binary — those are the policy
gaps, and they are the useful part.

Phase notes worth stating rather than glossing:

- `Provisioning` with `SupervisorNotConnected` is normal and transient. Wait.
- A gateway restart can bounce a running sandbox back to `Provisioning`.
- `Stopped` retains policy, providers, services, and persistent workspace data.
- `Error` means read `openshell logs <name>` before anything else.
- Empty results are ambiguous: it may be the wrong gateway or the wrong
  workspace, not an absent sandbox. Say which you queried.

Do not widen policy from this skill. Hand denials to `/actionboard-v5-agentformation:policy-widen`.
