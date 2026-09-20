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
   because it looks ready.

4. **Show the whole plan at once.** Run every provision with `--dry-run` and
   present one table: Agent, sandbox name, profile, CPU/memory/GPU, policy, egress
   destinations. This is the last cheap moment to catch an over-wide grant.

5. **Gate.** Wait for explicit approval. Then create in dependency order — Black
   first so the orchestrator is live before its workers, Red last so it observes a
   fully assembled harness.

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/openshell-admin/scripts/openshell-provision.sh \
     --usecase <profile> --name <mission>-<agent> \
     --workspace "${OPENSHELL_WORKSPACE:-default}" \
     --tenant <tenant> --pod <pod> --mission <mission-id> --agent <agent>
   ```

6. **Return the harness manifest.** One block: each Agent, its sandbox name, phase,
   and exec prefix, plus the single teardown command for the whole set:

   ```bash
   openshell sandbox list --selector mission=<mission-id>
   ```

## Invariants

- One sandbox per Agent per mission. Shared sandboxes destroy the audit trail and
  the per-tenant metering the labels carry.
- Every sandbox gets `tenant`, `pod`, `agent`, and `mission` labels. Everything
  downstream — billing, forensics, teardown — is a selector query over these.
- Yellow's sandbox is the only one with write access, and it is deleted rather
  than recycled when its ActionList completes.
- If any Agent's provision fails, report which succeeded and which did not, and
  stop. A partially formed harness runs a mission with a silently missing Agent.
