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

`{slug}` is the mission objective in kebab-case, truncated to 48 characters — for example
`add-health-endpoint-to-express-app`. `{n}` is a 1-based index in the order the items appear
in the Markdown.

Every list gets both a container `@id` and per-item `@id`s. Do not invent a shorter scheme
when a mission has only one scope item: `mission-plan` and `mission-report` reference these
identifiers by name, and a document that numbered its items differently silently fails to
join the graph.

The two **global** scopes are what make this a knowledge base rather than three loose files.
Agent and file `@id`s do not carry the mission slug, so once several missions are indexed
together the graph answers questions no single document can: which Agent has touched
`src/auth.ts` across every mission, which files carry the most `FailedActionStatus`
assignments, how often Yellow Agent blocked on the same acceptance criterion.

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
   severity is `L`, `M`, or `H`.

Tell the user they can validate the result at
[validator.schema.org](https://validator.schema.org) or Google's Rich Results Test.
