# KB — ActionBoard V5 Mission Knowledge Format (schema.org JSON-LD)

Every ActionBoard V5 mission document is emitted twice: once as **Markdown** for humans, once as
**JSON-LD using the [schema.org](https://schema.org) vocabulary** for machines. JSON-LD +
schema.org is the open format Google's [Knowledge Graph Search API](https://developers.google.com/knowledge-graph)
returns and the format Google recommends for structured data, so mission output drops
straight into a knowledge base, a graph store, or a search index without a transform step.

The three mission documents share one identifier scheme. Concatenate their `@graph` arrays
and you get a single valid knowledge base — no reconciliation pass required.

## Document envelope

Every `.jsonld` file uses the same shape:

```json
{
  "@context": "https://schema.org",
  "@graph": [ /* entities */ ]
}
```

`@graph` is the standard JSON-LD construct for a document describing multiple entities, and
Google's structured-data tooling consumes it directly. Never emit a bare array or a
single-entity object — the merge property depends on the envelope.

## Identifier scheme

Identifiers are opaque URNs so they stay stable when files move between repos.

| Entity | `@id` pattern | Scope |
|--------|---------------|-------|
| Mission | `urn:voltron:mission:{slug}` | per mission |
| Mission Brief | `urn:voltron:mission:{slug}:brief` | per mission |
| Mission Plan | `urn:voltron:mission:{slug}:plan` | per mission |
| Mission Report | `urn:voltron:mission:{slug}:report` | per mission |
| Scope list | `urn:voltron:mission:{slug}:scope` | per mission |
| Scope item | `urn:voltron:mission:{slug}:scope:{n}` | per mission |
| Out-of-scope list | `urn:voltron:mission:{slug}:out-of-scope` | per mission |
| Out-of-scope item | `urn:voltron:mission:{slug}:out-of-scope:{n}` | per mission |
| Success-criteria list | `urn:voltron:mission:{slug}:success-criteria` | per mission |
| Success criterion | `urn:voltron:mission:{slug}:criterion:{n}` | per mission |
| Constraints list | `urn:voltron:mission:{slug}:constraints` | per mission |
| Constraint | `urn:voltron:mission:{slug}:constraint:{n}` | per mission |
| Agent assignment | `urn:voltron:mission:{slug}:assignment:{n}` | per mission |
| Skills-gap entry | `urn:voltron:mission:{slug}:gap:{n}` | per mission |
| Risk | `urn:voltron:mission:{slug}:risk:{n}` | per mission |
| Owned file | `urn:voltron:file:{repo-relative-path}` | **global** |
| Agent | `urn:voltron:lion:{red\|blue\|green\|yellow\|main}` | **global** |
| Execution-provenance list | `urn:voltron:mission:{slug}:provenance` | per mission |
| Execution-provenance record | `urn:voltron:mission:{slug}:provenance:{n}` | per mission |
| OpenShell gateway | `urn:voltron:gateway:{endpoint-host}[:{port}]` | **global** |
| Workspace | `urn:voltron:workspace:{endpoint-host}/{workspace}` | **global** |
| Sandbox | `urn:voltron:sandbox:{endpoint-host}/{workspace}/{sandbox}` | **global** |
| ActionBoard pod | `urn:voltron:pod:{pod-id}` | **global** |
| Identity provider | `urn:voltron:idp:{issuer-host}` | **global** |
| Authenticated subject | `urn:voltron:subject:{issuer-host}/{subject}` | **global** |

`{slug}` is the mission objective in kebab-case, truncated to 48 characters — for example
`add-health-endpoint-to-express-app`. `{n}` is a 1-based index in the order the items appear
in the Markdown.

Every list gets both a container `@id` and per-item `@id`s. Do not invent a shorter scheme
when a mission has only one scope item: `mission-plan` and `mission-report` reference these
identifiers by name, and a document that numbered its items differently silently fails to
join the graph.

The **global** scopes are what make this a knowledge base rather than three loose files.
Agent, file, gateway, workspace, sandbox, pod, identity-provider and subject `@id`s do not
carry the mission slug, so once several missions are indexed together the graph answers
questions no single document can: which Agent has touched `src/auth.ts` across every
mission, which files carry the most `FailedActionStatus` assignments, how often Yellow Agent
blocked on the same acceptance criterion — and, once provenance is recorded, which missions
ran against a given gateway, which subject authenticated them, and whether anything was ever
run against a dev identity pool by mistake.

**Why the gateway URN keys on the endpoint host, not the gateway name.** The gateway *name*
(`--name actionboard-cloud`) is a local registration alias. It is chosen per machine and is
not unique: two operators can point the same alias at two different control planes, and the
same control plane can be registered under two aliases. Keying the URN on the alias would
silently merge two gateways into one node. The endpoint host is unique, so it is the key; the
alias rides along as `alternateName`. Include the port only when it is not 443.

A **local** gateway has no network endpoint. Use `urn:voltron:gateway:local` for it, and
understand the exception: that one `@id` is machine-scoped, not global, because every machine
has its own local daemon. That is acceptable precisely because a local gateway is never
shared; do not extend the exception to anything else.

Workspace, sandbox and subject names are only unique inside a parent, so their URNs embed the
parent: a workspace inside its gateway, a sandbox inside its workspace, a subject inside the
issuer that minted it. Pod ids are ActionBoard-wide, so `urn:voltron:pod:{pod-id}` needs no
prefix. Lowercase every host; leave workspace, sandbox, pod and subject values exactly as the
tooling reported them.

## Type mapping

| Mission concept | `@type` | Carries |
|-----------------|---------|---------|
| Mission | `Project` | `name`, `description`, `identifier`, `startDate`, `endDate`, `member`, `subjectOf` |
| Brief / Plan / Report document | `Report` | `name`, `about`, `datePublished`, `abstract`, `creator`, `mainEntity` |
| Agent | `Organization` | `name`, `description`, `additionalType`, `additionalProperty` |
| Agent assignment | `Action` | `name`, `description`, `agent`, `object`, `result`, `actionStatus`, `error` |
| Owned file | `SoftwareSourceCode` | `name` (repo-relative path), `codeRepository` |
| Success criterion | `DefinedTerm` | `name`, `description`, `inDefinedTermSet` |
| Skills-gap entry | `DefinedTerm` | `name` (capability), `additionalProperty` |
| Risk | `Thing` | `name`, `description`, `additionalType: "Risk"`, `additionalProperty` |
| Scope / Out-of-scope / Success Criteria / Constraints | `ItemList` (container) wrapping `DefinedTerm` items | `name`, `itemListElement` |
| Execution-provenance record | `Action` + `additionalType: "ExecutionProvenance"` | `name`, `agent`, `instrument`, `object`, `participant`, `result`, `actionStatus`, `startTime`, `additionalProperty` |
| OpenShell gateway | `Service` + `additionalType: "https://schema.org/SoftwareApplication"` | `name` (endpoint host), `alternateName` (local alias), `url` (endpoint), `serviceType`, `additionalProperty` |
| Workspace | `Thing` | `name`, `identifier`, `additionalType: "Workspace"` |
| Sandbox | `Thing` | `name`, `identifier`, `additionalType: "Sandbox"`, `additionalProperty` |
| ActionBoard pod | `Organization` | `name`, `identifier`, `description`, `additionalType: "ActionBoardPod"` |
| Identity provider | `Organization` + `additionalType: "https://schema.org/SoftwareApplication"` | `name` (issuer host), `url` (issuer) |
| Authenticated subject | `Organization` (machine identity) or `Person` (human operator) | `name`, `identifier`, `memberOf` |

**Why `Organization` for a Agent.** schema.org restricts the range of `Action.agent` to
`Person` or `Organization`. A Agent is a named specialist unit that performs actions, so
`Organization` is the least-wrong type that keeps `agent` range-valid. Each Agent also
carries `"additionalType": "https://schema.org/SoftwareApplication"` so a consumer can tell
it is software rather than a company. Do not model Agents as `Person` — it validates but
misrepresents them.

**Severity, category, mitigation, and gap status** have no native schema.org property. They
ride on `additionalProperty` as `PropertyValue` pairs, which is the schema.org-sanctioned
extension point. Do not invent bare properties like `"severity": "H"` — they fall outside
the vocabulary and validators drop them.

**Why these types for the provenance nodes.** schema.org has no vocabulary for control
planes, tenancies, or compute sandboxes, so each of the six new concepts is pinned to the
nearest real type and disambiguated with `additionalType`, exactly as `Risk` and the Agents
already are. Nothing below invents a `@type`.

- **Gateway → `Service`.** A gateway is a hosted capability reached at a URL, which is what
  `Service` describes; `url` and `serviceType` are native. It carries
  `"additionalType": "https://schema.org/SoftwareApplication"` — the same full-URL form the
  Agents use — so a consumer can tell it is software, not a commercial service listing.
- **Provenance record → `Action`.** "This mission ran on that gateway as that subject" is an
  action, and `Action` is the only type that gives range-valid slots for all of it:
  `agent` (Person/Organization) for the subject, `instrument` (Thing) for the gateway,
  `object` (Thing) for the workspace, `participant` (Person/Organization) for the pod,
  `result` (Thing) for the sandboxes. It also reuses the `actionStatus` vocabulary below
  unchanged. `additionalType: "ExecutionProvenance"` keeps it distinguishable from an
  assignment, which lives under a different `@id` prefix anyway.
- **Pod → `Organization`.** The ActionBoard pod is a tenancy and billing label, and the thing
  it labels is a tenant. `Organization` keeps `participant` range-valid, by the same
  least-wrong reasoning used for Agents. A pod is **not** the gateway and never shares a node
  with one, even when the pod console hosts both.
- **Identity provider → `Organization`**, same rationale, so `memberOf` from the subject is
  range-valid.
- **Subject → `Organization` when the auth mode was client-credentials** (that flow can only
  authenticate a machine client) **and `Person` when the browser fallback authenticated a
  human.** Pick from `auth_mode`, not from how the subject string looks.
- **Workspace and sandbox → `Thing` + a bare-string `additionalType`**, the same escape hatch
  `Risk` uses. There is no range-valid schema.org property for "workspace is part of
  gateway", and inventing one would be dropped by validators, so the containment is carried
  two ways instead: it is embedded in the URN, and the provenance `Action` names the gateway
  and the workspace together in one node.

`"Risk"`, `"ExecutionProvenance"`, `"Workspace"`, `"Sandbox"` and `"ActionBoardPod"` are the
complete set of bare-string `additionalType` values this format uses. Do not coin a sixth
without adding it here — an unlisted value is indistinguishable from a typo.

## Status vocabulary

Agent status maps onto schema.org's `ActionStatusType` enumeration. This is the single most
useful mapping in the format: the Agent contract (`Status: done | blocked`) is already an
action-status machine, so a plan and a report differ only in these values.

| Mission state | `actionStatus` |
|---------------|----------------|
| Planned, awaiting go/no-go | `https://schema.org/PotentialActionStatus` |
| Dispatched, Agent working | `https://schema.org/ActiveActionStatus` |
| Agent reported `done` | `https://schema.org/CompletedActionStatus` |
| Agent reported `blocked` | `https://schema.org/FailedActionStatus` |

A blocked assignment additionally carries `error` with the blocking reason as a plain string.

Skills-gap status uses the mission vocabulary unchanged, as an `additionalProperty` value:
`covered`, `use-existing-skill:{name}`, or `needs-new-skill`.

## Execution provenance (optional)

A mission that ran its sandboxes on a shared, multi-tenant gateway is not attributable from
the documents alone: the graph records what was built and by which Agent, but not *where* it
ran or *as whom*. Execution provenance closes that gap. It is written by `mission-report`,
and only by `mission-report` — a brief and a plan describe intent, and intent has no
execution context yet.

**Emit it when a mission touched a gateway.** One `ItemList` container at
`urn:voltron:mission:{slug}:provenance`, and one `Action` record per distinct
(gateway, workspace, pod, subject) tuple the mission used — normally exactly one. Even with
one record, emit the container: this format's list convention has no singular short form.

**Omit the whole block when there was nothing to record.** A mission with no sandbox, and a
mission that ran only against a local gateway where attribution is trivially the local user,
both produce a valid report with no provenance nodes at all. See *Compatibility* below.

### What to record

| Fact | Where it lands | Source |
|------|----------------|--------|
| Gateway endpoint | `Service.url` on the gateway node | the URL the operator supplied |
| Gateway local alias | `Service.alternateName` | `--name` / `ACTIONBOARD_GATEWAY_NAME` |
| Auth mode | `additionalProperty` `auth_mode` on the record | the connect wrapper's `auth` line |
| Workspace | `Action.object` → workspace node | `--workspace` / `OPENSHELL_WORKSPACE` |
| ActionBoard pod label | `Action.participant` → pod node | `--pod` / `ACTIONBOARD_POD_ID` |
| Authenticated subject | `Action.agent` → subject node | `openshell whoami --output json` |
| Identity provider | `subject.memberOf` → idp node | the issuer the operator supplied |
| Roles, scopes | `additionalProperty` on the record | `openshell whoami` |
| Sandboxes created | `Action.result` → sandbox nodes | the provision wrapper |
| Verification performed | `additionalProperty` `verified_by` | the commands actually run |

`actionStatus` on the record follows the vocabulary above: `CompletedActionStatus` once
`whoami` and `workspace list` both succeeded, `FailedActionStatus` plus an `error` string if
the connect or the verification failed. A gateway that was registered but never verified is
`ActiveActionStatus`, not `Completed` — the same honesty rule the report applies to
assignments.

An assignment may additionally point at the sandbox it ran in with
`"instrument": {"@id": "urn:voltron:sandbox:..."}`. That property is optional and additive;
an assignment without it is unchanged and still valid.

### Never record a credential

**No credential value goes in a mission graph. Ever.** Not in a node, not in an
`additionalProperty`, not in a `description`, not in an `error` string, not redacted, not
truncated, not hashed. Specifically prohibited: the ActionBoard one-time token
(`ACTIONBOARD_POD_TOKEN`), the OIDC client secret
(`OPENSHELL_OIDC_CLIENT_SECRET`), any access / ID / refresh token or raw JWT, any
`Authorization` header, session cookie, private key, or cloud access key.

Record the **subject** and the **identity provider** instead. Both are non-secret, both are
stable, and together they are exactly what an audit needs: they answer "who ran this, and
who vouched for them" without ever putting a bearer credential on disk. Roles, scopes,
audience and client id are configuration rather than secrets and may be recorded; the client
*secret* may not.

Two traps worth naming. A decoded access token contains the subject — take the subject from
`openshell whoami`, never by pasting a token in and letting a reader decode it back out. And
an `error` string is the usual leak: a provider's raw error body can echo the credential it
rejected, so write your own one-line reason instead of pasting the response.

### Worked example — provenance

Provenance for a mission that ran one sandbox on a remote gateway. Hosts here are
`.example` placeholders: no gateway, issuer, or identity-pool default ships with this format,
and a dev pool must never be recorded as if it were the tenant's.

```json
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "ItemList",
      "@id": "urn:voltron:mission:add-health-endpoint:provenance",
      "name": "Execution provenance",
      "itemListElement": [
        { "@id": "urn:voltron:mission:add-health-endpoint:provenance:1" }
      ]
    },
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
        { "@type": "PropertyValue", "name": "roles",    "value": "workspace:developer" },
        { "@type": "PropertyValue", "name": "scopes",   "value": "openshell:all" },
        { "@type": "PropertyValue", "name": "cli_version", "value": "0.0.110" }
      ]
    },
    {
      "@type": "Service",
      "@id": "urn:voltron:gateway:gw.pod-4471.actionboard.example",
      "additionalType": "https://schema.org/SoftwareApplication",
      "name": "gw.pod-4471.actionboard.example",
      "alternateName": "actionboard-cloud",
      "url": "https://gw.pod-4471.actionboard.example",
      "serviceType": "OpenShell gateway",
      "additionalProperty": {
        "@type": "PropertyValue", "name": "gateway-kind", "value": "remote"
      }
    },
    {
      "@type": "Thing",
      "@id": "urn:voltron:workspace:gw.pod-4471.actionboard.example/tenant-acme",
      "additionalType": "Workspace",
      "name": "tenant-acme",
      "identifier": "tenant-acme"
    },
    {
      "@type": "Thing",
      "@id": "urn:voltron:sandbox:gw.pod-4471.actionboard.example/tenant-acme/red-health-01",
      "additionalType": "Sandbox",
      "name": "red-health-01",
      "additionalProperty": [
        { "@type": "PropertyValue", "name": "usecase", "value": "coding" },
        { "@type": "PropertyValue", "name": "policy",
          "value": "policies/actionboard-cloud.yaml" }
      ]
    },
    {
      "@type": "Organization",
      "@id": "urn:voltron:pod:acme-prod",
      "additionalType": "ActionBoardPod",
      "name": "acme-prod",
      "identifier": "acme-prod",
      "description": "ActionBoard tenancy and billing label. Not the gateway, not the workspace."
    },
    {
      "@type": "Organization",
      "@id": "urn:voltron:subject:idp.actionboard.example/svc-voltron-runner",
      "additionalType": "https://schema.org/SoftwareApplication",
      "name": "svc-voltron-runner",
      "identifier": "svc-voltron-runner",
      "memberOf": { "@id": "urn:voltron:idp:idp.actionboard.example" }
    },
    {
      "@type": "Organization",
      "@id": "urn:voltron:idp:idp.actionboard.example",
      "additionalType": "https://schema.org/SoftwareApplication",
      "name": "idp.actionboard.example",
      "url": "https://idp.actionboard.example"
    }
  ]
}
```

The report's `Report` node links the block with
`"mentions": {"@id": "urn:voltron:mission:{slug}:provenance"}` so the container is reachable
from the document root and is not an island.

### Compatibility

**Every addition in this section is optional and additive. Nothing here changes an existing
type, renames an identifier, or makes a previously optional field required.** A Mission
Brief, Mission Plan, or Mission Report written before provenance existed validates unchanged
against this format, and so does a new one that omits provenance because the mission had no
sandbox or ran locally. The only hard rule is conditional: *if* a provenance node is present,
its `@id` references must resolve, like every other reference in the format.

## Output location

Write both files per document into a per-mission directory in the user's project:

```
./actionboard-v5-missions/{YYYY-MM-DD}-{slug}/
  mission-brief.md     mission-brief.jsonld
  mission-plan.md      mission-plan.jsonld
  mission-report.md    mission-report.jsonld
```

Confirm the directory with the user before the first write of a mission. If the project
already has a conventional docs location, offer that instead — never create a top-level
directory in someone's repo without asking.

## Worked example

A two-assignment mission, at plan stage:

```json
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Project",
      "@id": "urn:voltron:mission:add-health-endpoint",
      "name": "Add a /health endpoint to the Express app",
      "description": "Expose service version and uptime on an unauthenticated /health route.",
      "identifier": "add-health-endpoint",
      "startDate": "2026-09-02",
      "member": [{ "@id": "urn:voltron:lion:red" }],
      "subjectOf": { "@id": "urn:voltron:mission:add-health-endpoint:plan" }
    },
    {
      "@type": "Report",
      "@id": "urn:voltron:mission:add-health-endpoint:plan",
      "name": "Mission Plan — Add a /health endpoint to the Express app",
      "about": { "@id": "urn:voltron:mission:add-health-endpoint" },
      "datePublished": "2026-09-02",
      "creator": { "@id": "urn:voltron:lion:main" },
      "abstract": "One assignment, one risk. Awaiting go/no-go.",
      "mainEntity": {
        "@type": "ItemList",
        "itemListElement": [
          { "@id": "urn:voltron:mission:add-health-endpoint:assignment:1" }
        ]
      }
    },
    {
      "@type": "Organization",
      "@id": "urn:voltron:lion:main",
      "additionalType": "https://schema.org/SoftwareApplication",
      "name": "Black Agent",
      "description": "Mission commander (Black Agent). Plans, delegates, gates, reports."
    },
    {
      "@type": "Organization",
      "@id": "urn:voltron:lion:red",
      "additionalType": "https://schema.org/SoftwareApplication",
      "name": "Red Agent",
      "description": "Rapid execution specialist. Writes code, scaffolds features.",
      "additionalProperty": {
        "@type": "PropertyValue",
        "name": "specialty",
        "value": "rapid-execution"
      }
    },
    {
      "@type": "Action",
      "@id": "urn:voltron:mission:add-health-endpoint:assignment:1",
      "name": "Implement GET /health",
      "description": "Return {status, version, uptime} as JSON with a 200 status.",
      "agent": { "@id": "urn:voltron:lion:red" },
      "object": { "@id": "urn:voltron:file:src/routes/health.ts" },
      "actionStatus": "https://schema.org/PotentialActionStatus",
      "result": {
        "@type": "DefinedTerm",
        "name": "acceptance",
        "description": "curl localhost:3000/health returns 200 with a version field."
      }
    },
    {
      "@type": "SoftwareSourceCode",
      "@id": "urn:voltron:file:src/routes/health.ts",
      "name": "src/routes/health.ts"
    },
    {
      "@type": "Thing",
      "@id": "urn:voltron:mission:add-health-endpoint:risk:1",
      "additionalType": "Risk",
      "name": "Health route leaks build metadata",
      "additionalProperty": [
        { "@type": "PropertyValue", "name": "category", "value": "technical" },
        { "@type": "PropertyValue", "name": "severity", "value": "M" },
        { "@type": "PropertyValue", "name": "mitigation",
          "value": "Return only semver, never commit SHA or env vars." }
      ]
    }
  ]
}
```

Every `{"@id": ...}` reference in that example resolves to a node in the same document, which
is the property to preserve: in real output every entity referenced by `@id` must appear as a
node in some document of the mission. Dangling references are the one hard error in this
format — a graph store silently creates an empty stub for each one, and the mission's history
quietly develops holes.

## Before writing a `.jsonld` file

1. **Parse it.** `python3 -c "import json,sys; json.load(open(sys.argv[1]))" path.jsonld`.
   Never hand the user a file you have not confirmed parses.
2. **Check for dangling `@id`s.** Every `{"@id": "..."}` reference resolves to a node with
   that `@id`, either in this document or in a sibling mission document.
3. **Check the enumerations.** `actionStatus` is one of the four full schema.org URLs above;
   severity is `L`, `M`, or `H`; every bare-string `additionalType` is one of `Risk`,
   `ExecutionProvenance`, `Workspace`, `Sandbox`, `ActionBoardPod`.
4. **Scan for credential values.** Run this on every graph, not only ones with provenance. A
   hit is a stop-and-fix, never a lint warning to wave through:

   ```bash
   grep -nEiC1 '"(token|access_?token|id_?token|refresh_?token|client_?secret|secret|password|authorization|bearer|api_?key)"[[:space:]]*:|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' path.jsonld
   ```

   The first alternative catches a credential-shaped property name; the second catches a raw
   JWT by its `eyJ` base64 prefix, which is how one arrives when someone pastes a `whoami`
   response wholesale. A value is prohibited under an innocent property name too — the grep
   is a floor, not a proof. Run it against `.jsonld` output, not against this document: the
   prohibition prose above matches it by design.
5. **Check the provenance block, if one is present.** Skip this entirely when there is none —
   provenance is optional. When there is one: the container
   `urn:voltron:mission:{slug}:provenance` exists and every `itemListElement` resolves; each
   record's `agent`, `instrument`, `object`, `participant` and `result` resolve to nodes in
   the document; the gateway node's URN host matches the host in its `url`; the subject is
   typed `Organization` for a client-credentials `auth_mode` and `Person` for a browser
   login; and no gateway, issuer, or identity-pool value was filled in from a default rather
   than from what the operator actually supplied.

Tell the user they can validate the result at
[validator.schema.org](https://validator.schema.org) or Google's Rich Results Test.
