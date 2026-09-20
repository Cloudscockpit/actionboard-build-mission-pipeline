---
name: sandbox-down
description: Stop or delete OpenShell sandboxes for a finished mission, optionally archiving the workspace first. Use when a mission or ActionList completes.
argument-hint: "<sandbox-name or selector> [stop|delete]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-teardown.sh *) Bash(openshell sandbox list *)
---

# Tear down

Target: **$ARGUMENTS**

Teardown is user-invoked only. Claude does not decide a mission is over.

Default to **stop** unless the user says delete. Stop releases compute and keeps
the record, policy, providers, services, and persistent workspace data — a mission
that resumes should never have been deleted.

```bash
# release compute, keep state
${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-teardown.sh \
  --name <name> --stop

# destroy, purging injected credentials
${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-teardown.sh \
  --selector mission=<id> --delete --archive ./archives
```

Before any delete:

1. List exactly what matches and show it to the user. A selector can match more
   than they think.
2. Offer `--archive` if the workspace holds mission output. Download refuses
   sources outside the sandbox's canonical working directory, so archive what is
   in `/workspace`, not what the agent scattered elsewhere.
3. Confirm. Delete is irreversible and purges credentials.

Red Agent sandboxes are deleted rather than recycled once the ActionList
completes — a reused write-capable sandbox destroys the per-ActionList audit trail.
