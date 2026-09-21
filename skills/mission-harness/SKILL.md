---
name: mission-harness
description: Build the sandbox harness for a ActionBoard V5 mission — one isolated environment per assigned Agent, sized and policed by role, created only after go/no-go. Use when forming ActionBoard V5 for real execution.
argument-hint: "<mission-id> [agents: black,green,blue,yellow,red]"
context: fork
agent: sandbox-warden
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-provision.sh *) Bash(openshell *)
---

# Mission harness

Mission: **$ARGUMENTS**

ActionBoard V5 AgentFormation cannot act alone and form only on an explicit go/no-go. This skill
builds the execution substrate for that formation: one sandbox per Agent, each with
the narrowest policy its role needs, all labelled to the same mission so the whole
harness can be found, metered, and torn down as a unit.

## Sequence

0. **Pick the gateway, and connect it if it is a cloud pod.** The whole harness
   goes on **one** explicitly named gateway. For an ActionBoard cloud pod, run
   **`/pod-connect`** first and let it verify the identity the gateway actually
   sees; provisioning against an unauthenticated cloud gateway fails per-sandbox
   and leaves a half-built harness. For a local gateway, confirm it:

   ```bash
   openshell gateway list                 # * marks the active one
   ```

   Then hold that name for every command in this skill. Never let a step fall
   back to the active selection — between two provisions, anything can change it.

1. **Read the assignment.** Determine which Agents the mission brief actually
   assigned. Do not provision all five by reflex — an unused sandbox is cost and
   attack surface with no audit value.

2. **Map roles to profiles.** From
   `${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/references/agent-profiles.md`:

   | Agent | Profile | Mutates? |
   |---|---|---|
   | Black / Orchestrator | `orchestrator` | No — hands mutations to Red |
   | Green / Data | `data` | No |
   | Blue / Analysis | `analysis` | No |
   | Red / Action | `action` | **Yes** — enforce, per-path allow, deny destructive |
   | Yellow / Defense-Audit | `defense` | No — read-only, audit enforcement |

3. **Collect the real destinations.** Each profile template ships with `REPLACE_`
   placeholders. Ask for the actual hosts the mission needs *before* creating
   anything; a harness of sandboxes that can reach nothing is worse than none,
   because it looks ready. Against a remote gateway this is enforced rather than
   advised: the wrapper exits non-zero on a surviving `REPLACE_`, so an unresolved
   template stops the harness at the first sandbox instead of the fifth.

4. **Show the whole plan at once.** Run every provision with `--dry-run` and
   present one table: Agent, sandbox name, profile, CPU/memory/GPU, policy, egress
   destinations, and the gateway and workspace every row shares. This is the last
   cheap moment to catch an over-wide grant or a row pointing somewhere else.

5. **Gate.** Wait for explicit approval. Then create in dependency order — Black
   first so the orchestrator is live before its workers, Yellow last so it observes a
   fully assembled harness.

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-provision.sh \
     --usecase <profile> --name <mission>-<agent> \
     --gateway <gateway-name> \
     --workspace "${OPENSHELL_WORKSPACE:-default}" \
     --tenant <tenant> --pod <pod> --mission <mission-id> --agent-role <agent>
   ```

6. **Return the harness manifest.** One block: the gateway and workspace, then each
   Agent, its sandbox name, phase, and exec prefix, plus the single teardown
   command for the whole set:

   ```bash
   openshell sandbox list -g <gateway-name> --selector mission=<mission-id>
   ```

## Remote / cloud gateway

- `/pod-connect` is step 0, not a recovery step. Do not start provisioning and
  authenticate when the first one fails.
- Every sandbox in the harness targets the **same** explicitly named gateway and
  the same tenant workspace. A harness split across two gateways cannot be listed,
  metered, or torn down as a unit, which defeats the point of it.
- Images must be registry references. `--image ./dir` and Dockerfile builds are
  built by the CLI on *this* machine's Docker daemon, which the gateway cannot
  see; the wrapper refuses them. Push once and reuse the reference for all five.
- GPU selection uses the Kubernetes driver key, not the Docker one. See
  `references/agent-profiles.md` → `## Local vs remote/cloud gateway capability matrix`.
- Teardown of this harness must name the gateway: `--delete` refuses to infer it.

## Invariants

- One sandbox per Agent per mission. Shared sandboxes destroy the audit trail and
  the per-tenant metering the labels carry.
- Every sandbox gets `tenant`, `pod`, `agent`, and `mission` labels. Everything
  downstream — billing, forensics, teardown — is a selector query over these. On a
  shared gateway they stop being a recommendation: unlabelled sandboxes are
  indistinguishable from another tenant's and cannot be safely selected for delete.
  The `agent=` label comes from `--agent-role`; `--agent` is the sandbox's trailing
  command (default `claude`) and setting a role there produces a broken sandbox.
- `--pod` is the ActionBoard tenancy and billing label. It never selects where a
  sandbox is created; `--gateway` does.
- Red's sandbox is the only one with write access, and it is deleted rather
  than recycled when its ActionList completes.
- If any Agent's provision fails, report which succeeded and which did not, and
  stop. A partially formed harness runs a mission with a silently missing Agent.
