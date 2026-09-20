---
name: sandbox-status
description: Show OpenShell sandboxes for a mission, tenant, or Agent, with phase, policy revision, and recent denials. Use to check whether an agent environment is ready or being blocked.
argument-hint: "[selector or sandbox name] — e.g. mission=m-4471"
allowed-tools: Bash(openshell sandbox list *) Bash(openshell sandbox get *) Bash(openshell logs *) Bash(openshell service list *) Bash(openshell settings get *)
---

# Sandbox status

Target: **$ARGUMENTS**

If the argument looks like `k=v`, treat it as a label selector; otherwise treat it
as a sandbox name. With no argument, list everything in the current workspace.

```bash
openshell sandbox list --selector "$ARGUMENTS" -o json
openshell sandbox get <name> --output json
openshell logs <name> --source sandbox --since 30m --level warn
openshell service list <name>
```

Report as a compact table: name, agent, phase, policy source and revision, exposed
services. Then, separately, any `action=deny` lines from the last window grouped by
host and binary — those are the policy gaps, and they are the useful part.

Phase notes worth stating rather than glossing:

- `Provisioning` with `SupervisorNotConnected` is normal and transient. Wait.
- A gateway restart can bounce a running sandbox back to `Provisioning`.
- `Stopped` retains policy, providers, services, and persistent workspace data.
- `Error` means read `openshell logs <name>` before anything else.

Do not widen policy from this skill. Hand denials to `/actionboard-v5-agentformation:policy-widen`.
