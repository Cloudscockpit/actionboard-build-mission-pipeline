---
name: mission-report
description: Write a ActionBoard V5 Mission Report recording what each Agent shipped, blocked on, or deferred, as Markdown plus a schema.org JSON-LD knowledge graph. Use when the user asks to "write the mission report", "summarize the mission", "what shipped", or after Agents report back at the end of the ActionBoard V5 mission flow, and whenever a report must be exported as structured or machine-readable output.
---

# Mission Report — Markdown + Knowledge Graph

Emits the third and final ActionBoard V5 mission document: the outcome of every assignment, recorded
against the same graph nodes the plan created.

**Read the format reference first:** `${CLAUDE_PLUGIN_ROOT}/kb/mission-knowledge-format.md`.
The report's value depends entirely on reusing the plan's identifiers — a report that mints
fresh `@id`s records nothing, because nothing links back to what was promised.

## What a report contains

| Section | Content | Graph effect |
|---------|---------|-------------|
| Outcome | One line per assignment: shipped / blocked / deferred | `Action.actionStatus` transition |
| Mission Log | Each Agent's report verbatim-ish, in dispatch order | `Action.result` / `Action.error` |
| Success Criteria | Each brief criterion marked met or unmet, with evidence | `DefinedTerm` + evidence |
| Deferred | What was cut, and why | `Action` left `Potential`, with a reason |
| Execution Provenance *(optional)* | Where the mission ran and as whom | `ItemList` of `ExecutionProvenance` `Action`s |

## Procedure

1. **Load the plan's graph.** Read `mission-plan.jsonld` and reuse every `@id` — mission,
   assignments, Agents, files. The report does not create assignments; it resolves them.
2. **Transition each assignment's status** using the KB's `actionStatus` vocabulary:
   Agent reported `done` → `CompletedActionStatus`; Agent reported `blocked` →
   `FailedActionStatus` plus an `error` string naming the blocker; never dispatched →
   left at `PotentialActionStatus` with a `result` explaining the deferral.
3. **Record results honestly.** `result` carries what the Agent actually produced. If a Agent
   reported `done` but its acceptance criterion was never checked, that is not
   `CompletedActionStatus` — mark it `Active` and say the verification is outstanding.
4. **Check success criteria against evidence**, not against assignment status. An assignment
   can complete while its criterion still fails. Cite the evidence — a command's output, a
   test result, a file that now exists — for each criterion marked met.
5. **Record execution provenance — only if the mission touched a gateway.** See the section
   below. Skip it entirely for a mission with no sandbox, or one that ran locally.
6. **Set `endDate`** on the mission node.
7. **Write `mission-report.md`**, then `mission-report.jsonld`. Validate per the KB checklist,
   including the credential scan, and report both paths.

## Writing rules

- Report what happened, not what was supposed to happen. A mission where two of five
  assignments blocked is a useful record; a report that rounds it to "mission complete" is
  not, and the graph will contradict it.
- Every `FailedActionStatus` needs an `error` a reader can act on. "Failed" alone is noise.
- Do not quietly drop an assignment that was never dispatched. Deferred work stays in the
  graph with its reason, or the next mission rediscovers it as new.
- Keep the Markdown short. The detail lives in the graph; the Markdown is the summary someone
  reads in thirty seconds.
- **Never write a credential into a report — the Markdown or the graph.** Not the one-time
  token, not the OIDC client secret, not an access, ID, or refresh token, not an
  `Authorization` header, not redacted and not truncated. Record the subject and the identity
  provider instead; those are non-secret and are what an audit actually needs.

## Execution provenance

A mission that ran on a remote, multi-tenant gateway is unattributable from the report alone.
The graph says what shipped and which Agent shipped it, and nothing about **where it ran** or
**as whom** — so a reader six months later cannot tell whether the work landed in the
customer's tenant or somebody's dev pool. Provenance is the section that answers that, and
the report is the only one of the three documents that can write it: a brief and a plan
describe intent, and intent has no execution context yet.

**Emit it only when the mission actually touched a gateway.** A mission with no sandbox, and
a mission that ran against the local daemon where attribution is trivially the local user,
both produce a complete and valid report with this section absent. It is optional by
construction — see the KB's *Compatibility* note. Do not fabricate a provenance block to make
a report look thorough.

Take every value from what the connect step reported (`openshell whoami --output json`,
`openshell workspace list`, and the wrapper's handoff block), not from a policy file, a
config default, or an earlier mission. There is no gateway, issuer, or identity-pool default
in this plugin, and reusing one from a template is how a mission gets recorded against the
wrong tenant.

### The Markdown section

Place it after Deferred, before any appendix. One table, no prose:

```markdown
## Execution Provenance

| Fact | Value |
|------|-------|
| Gateway | `actionboard-cloud` — `https://gw.pod-4471.actionboard.example` |
| Auth mode | oidc client-credentials (headless, one-time token) |
| Workspace | `tenant-acme` |
| ActionBoard pod | `acme-prod` |
| Subject | `svc-voltron-runner` |
| Identity provider | `idp.actionboard.example` |
| Roles / scopes | `workspace:developer` / `openshell:all` |
| Sandboxes | `red-health-01` |
| Verified by | `openshell whoami --output json`; `openshell workspace list` |
```

Gateway, pod, and workspace are **three different things** and each gets its own row. The pod
is the ActionBoard tenancy and billing label; the gateway is the OpenShell control plane; the
workspace is the isolation boundary inside that gateway. Collapsing them into one "environment"
row destroys the only thing this section exists to record.

### The graph nodes

Mirror the table into the `@graph` using the KB's provenance shape — one `ItemList` container
at `urn:voltron:mission:{slug}:provenance` and one `ExecutionProvenance` `Action` per
(gateway, workspace, pod, subject) tuple, plus the gateway, workspace, sandbox, pod, subject,
and identity-provider nodes those `@id`s resolve to. Link the container from the report node
so it is not an island:

```json
{
  "@type": "Report",
  "@id": "urn:voltron:mission:add-health-endpoint:report",
  "mentions": { "@id": "urn:voltron:mission:add-health-endpoint:provenance" }
}
```

```json
{
  "@type": "Action",
  "@id": "urn:voltron:mission:add-health-endpoint:provenance:1",
  "additionalType": "ExecutionProvenance",
  "name": "Executed on gateway gw.pod-4471.actionboard.example",
  "agent": { "@id": "urn:voltron:subject:idp.actionboard.example/svc-voltron-runner" },
  "instrument": { "@id": "urn:voltron:gateway:gw.pod-4471.actionboard.example" },
  "object": { "@id": "urn:voltron:workspace:gw.pod-4471.actionboard.example/tenant-acme" },
  "participant": { "@id": "urn:voltron:pod:acme-prod" },
  "result": [
    { "@id": "urn:voltron:sandbox:gw.pod-4471.actionboard.example/tenant-acme/red-health-01" }
  ],
  "actionStatus": "https://schema.org/CompletedActionStatus",
  "startTime": "2026-09-02T09:14:00Z",
  "additionalProperty": [
    { "@type": "PropertyValue", "name": "auth_mode",
      "value": "oidc client-credentials (headless, one-time token)" },
    { "@type": "PropertyValue", "name": "verified_by",
      "value": "openshell whoami --output json; openshell workspace list" },
    { "@type": "PropertyValue", "name": "roles",  "value": "workspace:developer" },
    { "@type": "PropertyValue", "name": "scopes", "value": "openshell:all" }
  ]
}
```

Those two are excerpts. The six nodes the `@id`s above point at — gateway, workspace,
sandbox, pod, subject, identity provider — are spelled out in full in
`${CLAUDE_PLUGIN_ROOT}/kb/mission-knowledge-format.md`, and every one of them must appear in
the report's `@graph` or the references dangle.

`actionStatus` uses the same vocabulary as an assignment and obeys the same honesty rule:
`CompletedActionStatus` only once `whoami` **and** `workspace list` both succeeded;
`FailedActionStatus` with an `error` if the connect or the verification failed;
`ActiveActionStatus` for a gateway registered but never verified. A sandbox that was created
on a gateway nobody verified is exactly the case this section exists to make visible.

Optionally, point each assignment at the sandbox it ran in with
`"instrument": {"@id": "urn:voltron:sandbox:..."}`. That is additive — an assignment without
it is unchanged and still valid — and it is what later lets the accumulated graph answer
which sandbox profile a blocked assignment was running under.

### What never goes in — Markdown or graph

**No credential value appears in a mission report in any form.** Not the ActionBoard one-time
token (`ACTIONBOARD_POD_TOKEN`), not the OIDC client secret
(`OPENSHELL_OIDC_CLIENT_SECRET`), not an access, ID, or refresh token, not a raw JWT, not an
`Authorization` header, session cookie, private key, or cloud access key. Not masked, not
partially redacted, not truncated to "the last four", not hashed. A redacted secret in a
committed report is still a disclosure of its length, its format, and the fact that it was
handled carelessly.

Record the **subject** and the **identity provider** instead. They are non-secret, they are
stable, and together they are precisely what an audit asks for: who ran this, and who vouched
for them. Roles, scopes, audience, client id, gateway endpoint, workspace, and pod are
configuration rather than secrets and belong in the report.

Two leak paths specific to this section:

- **Pasting a `whoami` response wholesale.** It is JSON and it looks harmless, but the same
  buffer often carries a token. Pull out `subject`, `identity_provider`, `roles`, and
  `scopes` by name; never paste the blob.
- **Copying a provider's error body into `error`.** An identity provider echoing back the
  credential it rejected is a normal thing for an identity provider to do. Write your own
  one-line reason.

Before handing over the file, run the KB's credential scan over `mission-report.jsonld` and
over `mission-report.md`. A hit stops the report.

## What the accumulated graph answers

Because Agent and file identifiers are global across missions (see the KB's identifier scheme),
a directory of mission reports answers questions no single report can: which files block most
often, which Agent's assignments most frequently need a second pass, which success criteria
keep recurring unmet. Mention this to the user once they have more than one mission on disk —
it is the reason the format exists.
