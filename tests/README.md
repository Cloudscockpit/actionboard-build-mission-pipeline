# tests/

The plugin's only automated regression signal. One entry point:

```bash
bash tests/smoke.sh        # or ./tests/smoke.sh
```

Exit `0` only if every check passed. One line per check (`PASS` / `FAIL` /
`SKIP`), then a count and a list of failures.

## Contract

- **Offline.** No network call, and no real `openshell` command that could reach a
  gateway. The dry-run checks put a throwaway stub first on `PATH`; it answers
  only `--version` and `gateway list --output json` and exits 97 on anything
  else, so a regression that lets a `--dry-run` talk to a gateway shows up as a
  failed check instead of a live API call.
- **No writes outside `$TMPDIR`.** Everything lands in a `mktemp -d` that is
  removed on exit. `OPENSHELL_AUDIT_LOG` is always redirected at a temp file, so
  the suite never appends to the repo-root `.openshell-audit.log`; the last check
  verifies that file's hash is unchanged across the run.
- **Read-only against the real CLI config.** `~/.config/openshell` is hashed
  before and after and must be byte-identical.
- **Idempotent.** Two consecutive runs produce identical output apart from the
  temp-directory path printed in the header.
- **No new dependencies.** bash + python3 only. `shellcheck` and `PyYAML` are
  used when present and reported as `SKIP` when not — a missing dev tool never
  fails the suite.

## Why the CLI stub is generated at runtime, not committed

A file named `openshell` checked into `tests/bin/` is an executable that shadows
the real CLI for anyone who puts the repo on their `PATH`, and it is the kind of
thing that gets copied into an image by accident. `smoke.sh` writes it into
`$TMPDIR/bin/` instead, so it exists only for the duration of the run.

## Fixtures

`fixtures/*.json` are PreToolUse / PostToolUse hook payloads
(`{"tool_input": {"command": "..."}}`), one per behaviour:

| prefix | drives | asserts |
|---|---|---|
| `guard-*-deny.json` | `hooks/guard-openshell.sh` | `permissionDecision == deny` + a reason long enough to act on |
| `guard-*-ask.json` | same | `permissionDecision == ask` |
| `guard-allow-*.json` | same | no decision emitted — these are the no-false-positive cases |
| `guard-evasion-*.json` | same | wrapper prefixes the guard should see through (see *Known gaps*) |
| `audit-*.json` | `hooks/audit-policy.sh` | the fake secret is absent from the log, the entry survives, and the credential *name* is still visible |

Every fixture must stay valid JSON — one check parses all of them. The
deliberately malformed payloads used for the fail-closed checks are written into
`$TMPDIR` by `smoke.sh` instead, for that reason.

**No fixture may contain a real or realistic credential.** The redaction
fixtures use the obvious fake `FAKE_SMOKE_TOKEN_0123456789_NOT_REAL`. A separate
check scans the whole repository for credential-shaped values and will fail if a
plausible one is ever added.

## What each section pins

| # | Section | Pins |
|---|---|---|
| 1 | shell syntax | `bash -n` + executable bit on every `*.sh`; `shellcheck` when present |
| 2 | policy YAML | every shipped policy `yaml.safe_load`s |
| 3 | JSON | the four shipped JSON files + every fixture |
| 4 | version agreement | `plugin.json` == `marketplace.json` == `actions-map.json` == `docs/index.html`, and `HOOK_CONTRACT_VERSION` in both hooks |
| 5 | skill frontmatter | `name` matches directory; the four preserved invariants; `allowed-tools` script paths exist and are executable |
| 6 | registry integrity | every skill resolves or is whitelisted external; every agent file exists; `requiredTools` ⊆ agent `tools:` |
| 7 | guard decisions | 22 deny/ask/allow cases incl. no-false-positive and fail-closed paths |
| 8 | secret redaction | four leak shapes + the awk no-python3 fallback |
| 8b | H-3 pairing | the deny **and** the audit entry must survive the same command wrapper |
| 9 | dry-run contract | stubbed CLI; nothing created, no token leaked, `~/.config/openshell` byte-identical |
| 9i | full lifecycle | the readiness loop and teardown, which no `--dry-run` reaches |
| 9j | bash 3.2 | static scan + the real 3.2 interpreter when one is present |
| 10 | no secrets | credential-shaped-value scan over the whole tree |
| 11 | docs vs code | every wrapper flag and slash command in the docs exists |

## Two things worth knowing about the harness itself

**Every embedded python block ends with `__END__`.** `consume()` fails the run
if it is missing. Without it an exception part-way through a block silently
drops every check after it and the suite just reports a smaller total — which
is how the `WRAPPERS` assertions went missing for one revision of this file.

**The `.openshell-audit.log` check is a delta check, not a hash check.** The
*installed* PostToolUse hook appends to that file on every Bash call any other
agent or session makes, so a whole-file hash comparison fails whenever someone
else is working. The suite instead asserts two narrower things that are immune
to concurrency: the pre-existing bytes are unchanged (append-only, never
rewritten or truncated), and no suite marker — the fake token, the temp path,
any `smoke-*` name — appears in the appended delta. Lines appended by other
activity are counted and reported, not failed.

## Known gaps encoded as failing checks

Any check that fails here is a defect in the plugin, not a broken test. Fix the
code, not the check. When this file was last updated the open set was:

**Guard/audit wrapper parity (H-3).** The guard resolves `env`, `command`,
`nohup`, `sudo`, `time`, `exec` and `bash -c`, but historically not `eval`,
`timeout`, `stdbuf`, `nice`, `ionice`, `watch` or `xargs`, so
`timeout 30 openshell sandbox delete --all-workspaces` was allowed through.
Because `hooks/audit-policy.sh` uses the **same** `WRAPPERS` tuple, those
commands also left no audit entry: the deny and the paper trail failed
together. That is why section 8b asserts both halves for every evasion fixture,
and why section 7 asserts the two tuples stay byte-identical — a fix that lands
in one hook and not the other restores half the hole silently.

**`HOOK_CONTRACT_VERSION`.** Both hooks must declare it and it must equal
`plugin.json`'s version. It is the only way an operator can check which hook is
actually live, since hooks execute from the installed plugin copy:

```bash
grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/marketplaces/*/hooks/*.sh
```

If the constant drifts from `plugin.json`, that command lies, which is worse
than not having it — hence the check.

## What is deliberately not scanned

`.openshell-audit.log` at the repo root. It is gitignored, machine-local, and
records command text by design; scanning it would report the operator's own
shell history as a repository secret.

## Reminder

These hooks run from the **installed** plugin copy under
`~/.claude/plugins/`, not from this working tree. A green run here says the
repository is correct; it says nothing about what is currently executing. See
*Updating an installed plugin* in the README.
