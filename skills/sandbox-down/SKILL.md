---
name: sandbox-down
description: Stop or delete OpenShell sandboxes for a finished mission, optionally archiving the workspace first. Use when a mission or ActionList completes.
argument-hint: "<sandbox-name or selector> [stop|delete] [-g <gateway>]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-teardown.sh *) Bash(openshell sandbox list *) Bash(openshell gateway list *)
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

# destroy, purging injected credentials — gateway must be named
${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-teardown.sh \
  --selector mission=<id> --delete --gateway <gateway-name> --archive ./archives
```

## `--delete` requires an explicit `--gateway`

The wrapper refuses to infer it from the active selection and exits non-zero
(`--gateway <name>`, or env `OPENSHELL_GATEWAY` / `ACTIONBOARD_GATEWAY_NAME`).
The active gateway is not a target, it is whatever the last command happened to
leave selected — and a selector like `mission=m-4471` will match in *any*
tenant that uses the same convention. Deleting into the wrong tenant on a
shared cloud gateway purges another team's credentials and mission state with
no undo. That is the highest-severity thing this plugin can do, so the name is
mandatory rather than convenient. `--stop` still accepts the active gateway.

```bash
openshell gateway list             # confirm the name before you type it
```

Before any delete:

1. List exactly what matches **on that gateway** and show it to the user. A
   selector can match more than they think.
2. Offer `--archive` if the workspace holds mission output. Download refuses
   sources outside the sandbox's canonical working directory, so archive what is
   in `/workspace`, not what the agent scattered elsewhere.
3. Confirm. Delete is irreversible and purges credentials.

Red Agent sandboxes are deleted rather than recycled once the ActionList
completes — a reused write-capable sandbox destroys the per-ActionList audit trail.
