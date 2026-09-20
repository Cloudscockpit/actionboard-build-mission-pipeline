# Risk Classification

Every action is classified before execution is planned. The output is a risk tier
(T1–T4) recorded on the action in the registry, and the tier travels with the
action into every ActionList that uses it.

Classification is a judgement about **what happens if this action is wrong**, not
about how likely it is to be wrong. Likelihood is what the gate measures from run
history; the tier sets how much proof that history has to supply.

## The four dimensions

Score each dimension 1–4. The schema stores these in `risk_scores`.

### Reversibility — can it be undone, and how fast?

| Score | Meaning |
| --- | --- |
| 1 | Trivially reversible. Re-run, revert, or ignore. No state left behind |
| 2 | Reversible with a known, tested rollback path inside minutes |
| 3 | Reversible in principle, but slow, manual, or partial. Rollback itself carries risk |
| 4 | Irreversible. Deleted data, sent message, moved funds, rotated credential, published artifact |

### Blast radius — who is affected if it goes wrong?

| Score | Meaning |
| --- | --- |
| 1 | One developer's workspace or a scratch environment |
| 2 | One service or one team's staging environment |
| 3 | A production service, or a shared dependency other teams build on |
| 4 | All tenants, all users, or the control plane itself |

### Data sensitivity — what does it read or write?

| Score | Meaning |
| --- | --- |
| 1 | Public or synthetic data only |
| 2 | Internal non-personal data |
| 3 | Customer data, or personal data under a retention or residency obligation |
| 4 | Credentials, key material, payment instruments, regulated records, audit logs |

### Reasoning fragility — how easily does a plausible-looking plan go wrong?

| Score | Meaning |
| --- | --- |
| 1 | Deterministic. One correct answer, mechanically checkable |
| 2 | Mostly determined; the few judgement calls are checkable against the end condition |
| 3 | Genuine judgement required. Inputs are ambiguous or the correct answer is context-dependent |
| 4 | Underspecified by nature. A confident wrong answer is indistinguishable from a right one without independent verification |

## Deriving the tier

**The tier is the highest dimension score, never the average.**

```
tier = T{max(reversibility, blast_radius, data_sensitivity, reasoning_fragility)}
```

Averaging is how a credential rotation with three 1s and one 4 becomes a "T2".
The one dimension that is a 4 is the whole reason the action is dangerous;
averaging it away is arithmetic laundering of risk.

| Tier | Name | Means |
| --- | --- | --- |
| T1 | Routine | Cheap to get wrong, cheap to undo |
| T2 | Standard | Real effect, known rollback, contained blast radius |
| T3 | Elevated | Production-affecting, slow to undo, or judgement-heavy |
| T4 | Restricted | Never autonomous, regardless of history |

## Policy-restricted classes — automatic T4

Set `policy_restricted: true` and the action is T4 regardless of its scores. No
run history promotes it. These classes are restricted because the failure mode is
not "the run failed" but "the failure is undiscoverable, unrecoverable, or
carries an obligation to someone outside the team":

- **Identity and access** — IAM, RBAC, auth configuration, session or token policy
- **Key material** — secrets, credentials, certificates, signing keys, rotation
- **Funds movement** — payments, refunds, invoicing, charges, payouts
- **Unrecoverable deletion** — dropping data, purging backups, destroying volumes
- **Audit and monitoring changes** — anything that alters what gets recorded or
  alerted, including disabling a check "temporarily"
- **Disclosure obligations** — anything that, done wrong, starts a regulatory or
  contractual notification clock

The audit/monitoring entry catches the case people miss: an action that changes
the observability surface can hide the evidence of every action after it.

## Writing the rationale

`risk_rationale` is required in practice even though the schema permits its
absence. A tier without a rationale cannot be challenged, so it drifts — usually
downward, under deadline pressure.

Write which dimension set the tier and why:

> T3 — blast_radius 3. Runs against the shared ingest cluster; a bad config takes
> down three downstream teams' pipelines, not just ours. Reversible in about 10
> minutes via the previous revision, so reversibility is 2.

Not:

> T3 — production deploy, needs care.

**Keep tier changes in review.** A tier that can be edited without a reviewer is a
tier that drifts. Treat registry changes like any other code change.

## When in doubt, classify one tier higher

An over-classified action costs you human approvals until its history justifies
promotion. An under-classified action runs autonomously before anyone has
evidence it should. The first is an inconvenience with a clear remedy; the second
is the failure this whole mechanism exists to prevent.

Evidence brings a tier down. Optimism should never bring one down.

## Backfill heuristics are not classifications

`scripts/backfill_registry.py` guesses a tier by keyword when seeding a registry
from history:

| Pattern matches | Guess |
| --- | --- |
| `secret`, `credential`, `key`, `token`, `iam`, `auth`, `rbac` | T4 |
| `billing`, `payment`, `invoice`, `charge`, `refund` | T4 |
| `migrat`, `schema`, `backfill`, `delete`, `drop`, `purge` | T3 |
| `infra`, `terraform`, `cluster`, `network`, `dns`, `prod` | T3 |
| `deploy`, `release`, `rollout`, `publish` | T2 |
| `docs`, `lint`, `format`, `test`, `chore`, `ci` | T1 |
| anything else | T2 |

Backfilled actions are written with `risk_rationale` set to
`"BACKFILL HEURISTIC — review and correct before first mission."` That string is
the marker for unreviewed classification. Every one of them needs a human pass
before the first mission, and the heuristic will get some wrong — it matches on
names, and names lie.

## One action, one effect

Classification assumes an action has a single effect that succeeds or fails on
its own. If an action can partially succeed, it is two actions.

Partial success is unscoreable, unscoreable stages count as failures, and so
compound actions never clear the gate — correctly, but confusingly. Splitting
them is the fix, not a threshold exception.
