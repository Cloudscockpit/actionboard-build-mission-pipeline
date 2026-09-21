---
name: sandbox-up
description: Provision an OpenShell sandbox for a Agent or a usecase, wait for Ready, and hand back the exec prefix. Use when an agent needs an isolated environment to run in.
argument-hint: "<usecase> [name] — e.g. action yellow-agent-01"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-provision.sh *) Bash(openshell whoami *) Bash(openshell gateway *) Bash(openshell workspace list *) Bash(openshell sandbox get *) Bash(openshell sandbox list *)
---

# Provision a sandbox

Request: **$ARGUMENTS**

Read `${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/references/agent-profiles.md` for the
profile table before choosing sizing or policy.

1. **Resolve the profile.** The first argument is the usecase
   (`orchestrator` `data` `analysis` `action` `defense` `train` `inference` `scratch`);
   the second, if present, is the sandbox name. If the usecase is missing or
   ambiguous, ask once — do not guess between `read-only` and `read-write`.

2. **Preflight — the gateway first, then the workspace.** Know which control
   plane you are about to create on before you check anything else:

   ```bash
   openshell gateway list                  # * marks the active one
   openshell whoami -g <gateway> --output json
   openshell workspace list -g <gateway>
   ```

   If `whoami` returns no identity, do not re-run it — it reports what the
   *gateway* validated, so it will fail identically forever. For an ActionBoard
   cloud pod run **`/pod-connect`**; for any other gateway run
   `openshell gateway login <name>`. See `references/troubleshooting.md` →
   `## Gateway auth failures`.

   Empty workspace rows mean the subject has no membership. Report the `subject`
   and stop; only a Platform Admin can fix it.

3. **Show the plan.** Run the wrapper with `--dry-run` and surface the resolved
   gateway, image, CPU, memory, GPU, policy file, and labels. Wait for the user
   to confirm.

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-provision.sh \
     --usecase <usecase> --name <name> \
     --gateway <gateway-name> \
     --workspace "${OPENSHELL_WORKSPACE:-default}" \
     --tenant <tenant> --pod <pod> --mission <mission> \
     --dry-run
   ```

   Always pass `--gateway` (env `OPENSHELL_GATEWAY`) rather than relying on the
   active selection, which is whatever the last command left behind. The plan
   block prints the resolved name with a `(remote)` suffix when it is a remote
   or cloud gateway. `--pod` is the ActionBoard tenancy label; it never selects
   where the sandbox is created.

4. **Create.** Re-run without `--dry-run`. The wrapper blocks until the gateway
   reports phase `Ready`. Do not report success from the compute side alone.

5. **Hand off.** Return only: sandbox name, gateway, workspace, phase, policy
   source and revision, exposed URLs, attached providers, and the
   `openshell sandbox exec -n <name> --` prefix the agent should use.

If the policy template still contains `REPLACE_` placeholders, say so plainly.
On a local gateway that is a warning and the sandbox will reach nothing until
real hosts are filled in. **Against a remote or cloud gateway the wrapper now
exits non-zero instead** — fill in the hosts and re-run. `policies/actionboard-cloud.yaml`
ships unresolved on purpose, so resolving it is the first step of the cloud
path, not a fault. The wrapper likewise refuses a local-dir or Dockerfile
`--image` remotely; push it and pass a registry reference.
