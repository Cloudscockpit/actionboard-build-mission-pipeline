---
name: policy-widen
description: Triage an OpenShell denial and add the narrowest policy rule that fixes it. Use when a sandboxed agent is blocked from a host, path, or credential.
argument-hint: "<sandbox-name> [host or denial text]"
allowed-tools: Bash(openshell logs *) Bash(openshell policy get *) Bash(openshell policy update *) Bash(openshell policy list *) Bash(openshell sandbox get *)
---

# Widen a policy, narrowly

Target: **$ARGUMENTS**

Read `${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/references/policy-recipes.md` for
spec grammar and `references/troubleshooting.md` for the denial triage table.

1. **Read the actual denial.** Never widen from a guess.

   ```bash
   openshell logs <name> --tail --source sandbox
   ```

   Each line carries host, port, binary, and reason. A connection needs the
   destination *and* the calling binary to match inside the same policy block, so
   a denial with the host already allowed usually means the binary is missing.

2. **Classify before acting.**

   | Reason | Fix |
   |---|---|
   | No matching endpoint or binary | `--add-endpoint host:port:access:protocol:enforce --binary <path>` |
   | Endpoint present, method/path blocked | `--add-allow 'host:port:METHOD:/path/**'` |
   | `credential_endpoint_mismatch` | Fix the **provider profile**, not the policy. Export it with `openshell provider profile export <id> -o yaml`. |
   | `request_authority_mismatch` | The client must send `Host:` including the non-default port. |

3. **Preview, then apply.**

   ```bash
   openshell policy update <name> --add-endpoint <spec> --binary <path> --dry-run
   openshell policy update <name> --add-endpoint <spec> --binary <path> --wait
   openshell policy list <name>
   ```

4. **Static sections cannot be hot-reloaded.** `filesystem_policy`, `landlock`, and
   `process` are locked at creation. If the fix needs one of them, say so and offer
   recreation rather than attempting an update that will be rejected.

Rules that hold regardless of what the user asks for: one endpoint at a time, name
the binary, never `access: full` as a shortcut, and never widen sandbox policy to
resolve a credential binding error.
