#!/usr/bin/env bash
# tests/smoke.sh -- offline regression suite for ActionBoard-V5-AgentFormation.
#
# Runs in a few seconds from a clean checkout with no network, no openshell
# gateway, and no dependencies beyond bash, python3 and the coreutils already
# required by the plugin's own scripts. shellcheck and PyYAML are used when
# present and SKIPped (never FAILed) when absent.
#
#   bash tests/smoke.sh          # or ./tests/smoke.sh
#
# Writes nothing outside $TMPDIR. Exits 0 only if every check passed.
#
# The openshell CLI is STUBBED into a temp PATH for the dry-run checks. The stub
# answers `--version` and `gateway list --output json` and hard-fails on
# anything else, so a regression that makes a --dry-run touch a real gateway
# shows up as a failed check rather than as a live API call. It is generated
# at runtime into $TMPDIR rather than committed, so this repository never
# carries an executable named `openshell` that could shadow the real CLI on
# someone's PATH.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
SCRIPTS="$ROOT/skills/openshell-admin/scripts"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ab-smoke.XXXXXX")" || { echo "cannot mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

N_PASS=0; N_FAIL=0; N_SKIP=0; FAILED=""

pass() { N_PASS=$((N_PASS+1)); printf 'PASS  %s\n' "$1"; }
fail() { N_FAIL=$((N_FAIL+1)); FAILED="$FAILED
  - $1"; printf 'FAIL  %s\n        %s\n' "$1" "${2:-}"; }
skip() { N_SKIP=$((N_SKIP+1)); printf 'SKIP  %s  (%s)\n' "$1" "${2:-}"; }
sect() { printf '\n== %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi; }

# Consume STATUS<TAB>NAME<TAB>DETAIL lines produced by an embedded python check.
# Each embedded python check block ends by printing __END__. Without that
# sentinel an exception part-way through the block would silently drop every
# check after it and the suite would just report a smaller total -- which is
# how the WRAPPERS assertions went missing while this file was being written.
consume() {
  local st nm det got_end=0
  while IFS="$(printf '\t')" read -r st nm det; do
    [ -z "${st:-}" ] && continue
    case "$st" in
      __END__) got_end=1 ;;
      PASS) pass "$nm" ;;
      FAIL) fail "$nm" "${det:-}" ;;
      SKIP) skip "$nm" "${det:-}" ;;
      *)    fail "malformed check output" "$st $nm $det" ;;
    esac
  done < "$1"
  if [ "$got_end" -ne 1 ]; then
    fail "check block $(basename "$1" .out) ran to completion" \
         "the embedded python exited early; every check after that point did not run"
  else
    pass "check block $(basename "$1" .out) ran to completion"
  fi
}

sha_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

printf 'ActionBoard-V5-AgentFormation smoke suite\n'
printf 'repo: %s\n' "$ROOT"
printf 'tmp : %s\n' "$TMP"

# Baseline for the "this suite writes nothing into the repo" check at the end.
# The audit log is the one repo-root file a buggy hook invocation could append
# to, and it is gitignored, so `git status` alone would not notice.
#
# Deliberately NOT a whole-file hash. The INSTALLED (not this-tree) PostToolUse
# hook appends to this same file on every Bash call any other agent or session
# makes, so a hash comparison fails whenever someone else is working -- and a
# check that cries wolf is a check that gets ignored. What actually matters is
# two narrower properties: the log was only appended to, never rewritten or
# truncated; and nothing the SUITE produced ended up in it. Both are checked
# against the delta at the end, and both are immune to concurrent activity.
AUDIT_LOG="$ROOT/.openshell-audit.log"
if [ -f "$AUDIT_LOG" ]; then
  cp "$AUDIT_LOG" "$TMP/audit.before"
  AUDIT_SIZE_BEFORE="$(wc -c < "$AUDIT_LOG" | tr -d ' ')"
else
  : > "$TMP/audit.before"
  AUDIT_SIZE_BEFORE=0
fi

# ---------------------------------------------------------------- 1. shell --
sect "1. shell syntax"
SH_COUNT=0
while IFS= read -r f; do
  SH_COUNT=$((SH_COUNT+1))
  if bash -n "$ROOT/$f" 2>"$TMP/syn.err"; then
    pass "bash -n $f"
  else
    fail "bash -n $f" "$(head -3 "$TMP/syn.err" | tr '\n' ' ')"
  fi
done <<EOF
$(cd "$ROOT" && find . -path ./.git -prune -o -name '*.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
EOF
if [ "$SH_COUNT" -ge 6 ]; then pass "found $SH_COUNT shell scripts (>=6 expected)"
else fail "shell script discovery" "only $SH_COUNT *.sh found; expected >= 6"; fi

while IFS= read -r f; do
  if [ -x "$ROOT/$f" ]; then pass "executable bit: $f"
  else fail "executable bit: $f" "not chmod +x; hooks.json and allowed-tools invoke it directly"; fi
done <<EOF
$(cd "$ROOT" && find . -path ./.git -prune -o -name '*.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
EOF

if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r f; do
    if shellcheck -S warning -x "$ROOT/$f" >"$TMP/sc.out" 2>&1; then
      pass "shellcheck $f"
    else
      fail "shellcheck $f" "$(head -6 "$TMP/sc.out" | tr '\n' ' ')"
    fi
  done <<EOF
$(cd "$ROOT" && find . -path ./.git -prune -o -name '*.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
EOF
else
  skip "shellcheck (all scripts)" "shellcheck not installed; bash -n still ran"
fi

# ----------------------------------------------------------------- 2. yaml --
sect "2. policy YAML"
if python3 -c 'import yaml' 2>/dev/null; then
  Y_COUNT=0
  for y in "$ROOT"/skills/openshell-admin/policies/*.yaml; do
    Y_COUNT=$((Y_COUNT+1))
    b="$(basename "$y")"
    if python3 -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' "$y" 2>"$TMP/y.err"; then
      pass "yaml.safe_load policies/$b"
    else
      fail "yaml.safe_load policies/$b" "$(head -3 "$TMP/y.err" | tr '\n' ' ')"
    fi
  done
  if [ "$Y_COUNT" -ge 9 ]; then pass "found $Y_COUNT policy templates (>=9 expected)"
  else fail "policy discovery" "only $Y_COUNT policies found"; fi
else
  skip "policy YAML parse" "PyYAML not installed"
fi

# ----------------------------------------------------------------- 3. json --
sect "3. JSON"
for j in .claude-plugin/plugin.json \
         .claude-plugin/marketplace.json \
         skills/skills-registry/actions-map.json \
         skills/actionboard-devops-mission/assets/action-registry.schema.json \
         hooks/hooks.json; do
  if [ ! -f "$ROOT/$j" ]; then fail "json $j" "file missing"; continue; fi
  if python3 -c 'import sys,json;json.load(open(sys.argv[1]))' "$ROOT/$j" 2>"$TMP/j.err"; then
    pass "json.load $j"
  else
    fail "json.load $j" "$(head -3 "$TMP/j.err" | tr '\n' ' ')"
  fi
done
FIX_COUNT=0
for j in "$FIX"/*.json; do
  FIX_COUNT=$((FIX_COUNT+1))
  if ! python3 -c 'import sys,json;json.load(open(sys.argv[1]))' "$j" 2>/dev/null; then
    fail "json.load fixtures/$(basename "$j")" "invalid JSON"
  fi
done
if [ "$FIX_COUNT" -ge 20 ]; then pass "all $FIX_COUNT fixtures are valid JSON"
else fail "fixture discovery" "only $FIX_COUNT fixtures found; expected >= 20"; fi

# -------------------------------------------------------------- 4. version --
sect "4. version agreement"
python3 - "$ROOT" >"$TMP/ver.out" <<'PY'
import json, os, re, sys
root = sys.argv[1]
T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)
p  = json.load(open(os.path.join(root, ".claude-plugin/plugin.json")))
m  = json.load(open(os.path.join(root, ".claude-plugin/marketplace.json")))
a  = json.load(open(os.path.join(root, "skills/skills-registry/actions-map.json")))
mp = m["plugins"][0]
v = p.get("version")
R("PASS" if re.match(r"^\d+\.\d+\.\d+$", v or "") else "FAIL",
  "plugin.json version is semver", "got %r" % (v,))
for label, got in (("marketplace.json plugins[0].version", mp.get("version")),
                   ("actions-map.json version", a.get("version"))):
    R("PASS" if got == v else "FAIL", "%s == plugin.json (%s)" % (label, v), "got %r" % (got,))
R("PASS" if mp.get("name") == p.get("name") else "FAIL",
  "marketplace plugin name == plugin.json name", "%r vs %r" % (mp.get("name"), p.get("name")))
# docs/index.html must not advertise a stale version
html = open(os.path.join(root, "docs/index.html"), encoding="utf-8").read()
vers = set(re.findall(r"v(\d+\.\d+\.\d+)", html)) | set(re.findall(r"New in (\d+\.\d+\.\d+)", html))
bad = sorted(x for x in vers if x != v)
R("PASS" if not bad else "FAIL", "docs/index.html advertises only version %s" % v,
  "also found: %s" % ", ".join(bad))

# The hooks are what actually enforce the security contract, and they execute
# from the INSTALLED plugin copy, not from this tree. HOOK_CONTRACT_VERSION is
# the only way an operator can check in one command which hook is really live:
#   grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/marketplaces/*/hooks/*.sh
# If it drifts from plugin.json, that command lies, which is worse than not
# having it.
for hook in ("hooks/guard-openshell.sh", "hooks/audit-policy.sh"):
    txt = open(os.path.join(root, hook), encoding="utf-8").read()
    m = re.search(r'^HOOK_CONTRACT_VERSION=["\']?([0-9]+\.[0-9]+\.[0-9]+)["\']?',
                  txt, re.M)
    if not m:
        R("FAIL", "%s declares HOOK_CONTRACT_VERSION" % hook,
          "absent: an operator cannot tell which hook version is installed and live")
    else:
        R("PASS", "%s declares HOOK_CONTRACT_VERSION" % hook)
        R("PASS" if m.group(1) == v else "FAIL",
          "%s HOOK_CONTRACT_VERSION == plugin.json (%s)" % (hook, v),
          "got %r" % (m.group(1),))
print("__END__")
PY
consume "$TMP/ver.out"

# ---------------------------------------------------- 5+6. skills/registry --
sect "5. skill frontmatter"
python3 - "$ROOT" >"$TMP/fm.out" <<'PY'
import os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)
try:
    import yaml
except ImportError:
    R("SKIP", "skill frontmatter", "PyYAML not installed")
    print("__END__"); raise SystemExit

def frontmatter(path):
    txt = open(path, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n", txt, re.S)
    if not m:
        return None
    return yaml.safe_load(m.group(1))

sk = os.path.join(root, "skills")
dirs = sorted(d for d in os.listdir(sk) if os.path.isdir(os.path.join(sk, d)))
R("PASS" if len(dirs) >= 13 else "FAIL", "found %d skill directories (>=13)" % len(dirs), "")
for d in dirs:
    p = os.path.join(sk, d, "SKILL.md")
    if not os.path.isfile(p):
        R("FAIL", "skills/%s/SKILL.md exists" % d, "missing"); continue
    try:
        fm = frontmatter(p)
    except Exception as e:
        R("FAIL", "skills/%s frontmatter parses" % d, str(e)[:120]); continue
    if fm is None:
        R("FAIL", "skills/%s frontmatter parses" % d, "no --- delimited block"); continue
    if not isinstance(fm, dict):
        R("FAIL", "skills/%s frontmatter parses" % d, "not a mapping"); continue
    R("PASS", "skills/%s frontmatter parses" % d)
    name = fm.get("name")
    R("PASS" if name == d else "FAIL", "skills/%s name field == directory" % d, "name=%r" % (name,))
    R("PASS" if (fm.get("description") or "").strip() else "FAIL",
      "skills/%s has a description" % d, "")
    # allowed-tools that name a shipped script must name a script that exists
    at = fm.get("allowed-tools") or ""
    for rel in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s)*]+\.sh)", at if isinstance(at, str) else " ".join(at)):
        fp = os.path.join(root, rel)
        ok = os.path.isfile(fp) and os.access(fp, os.X_OK)
        R("PASS" if ok else "FAIL", "skills/%s allowed-tools -> %s" % (d, rel),
          "missing or not executable")

INV = [
    ("sandbox-down",    "disable-model-invocation", True),
    ("mission-harness", "context",                  "fork"),
    ("mission-harness", "agent",                    "sandbox-warden"),
    ("openshell-admin",   "user-invocable",           False),
]
for d, key, want in INV:
    p = os.path.join(sk, d, "SKILL.md")
    try:
        fm = frontmatter(p) or {}
    except Exception:
        fm = {}
    got = fm.get(key, "<absent>")
    R("PASS" if got == want else "FAIL",
      "invariant: %s %s == %r" % (d, key, want), "got %r" % (got,))
print("__END__")
PY
consume "$TMP/fm.out"

sect "6. registry integrity"
python3 - "$ROOT" >"$TMP/reg.out" <<'PY'
import json, os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)

# Skills that deliberately resolve outside this repository.
EXTERNAL = {"graphify", "skill-creator"}

amp = os.path.join(root, "skills/skills-registry/actions-map.json")
data = json.load(open(amp))
types = data.get("actionTypes") or []
R("PASS" if len(types) >= 16 else "FAIL", "actions-map has %d action types (>=16)" % len(types), "registry looks truncated")

skdir = os.path.join(root, "skills")
agdir = os.path.join(root, "agents")

def agent_tools(agent):
    p = os.path.join(agdir, agent + ".md")
    if not os.path.isfile(p):
        return None
    txt = open(p, encoding="utf-8").read()
    m = re.search(r"^tools:\s*(.+)$", txt, re.M)
    if not m:
        return set()
    return {t.strip() for t in m.group(1).split(",") if t.strip()}

seen_actions = set()
for t in types:
    act = t.get("action", "<unnamed>")
    if act in seen_actions:
        R("FAIL", "action %r is unique" % act, "duplicate entry")
    seen_actions.add(act)
    ag = t.get("agent")
    tools = agent_tools(ag) if ag else None
    R("PASS" if tools is not None else "FAIL",
      "%s -> agents/%s.md exists" % (act, ag), "no such agent file")
    for s in t.get("skills") or []:
        ok = s in EXTERNAL or os.path.isfile(os.path.join(skdir, s, "SKILL.md"))
        R("PASS" if ok else "FAIL", "%s -> skill %r resolves" % (act, s),
          "not under skills/ and not whitelisted as external %s" % sorted(EXTERNAL))
    if tools:
        missing = [x for x in (t.get("requiredTools") or []) if x not in tools]
        R("PASS" if not missing else "FAIL",
          "%s requiredTools subset of %s tools" % (act, ag),
          "missing from agent frontmatter: %s" % ", ".join(missing))
    st = t.get("status")
    R("PASS" if st in ("covered", "conditional", "needs-new-skill") else "FAIL",
      "%s status is a known value" % act, "got %r" % (st,))

# hooks.json must point at hook files that exist and are executable
hj = json.load(open(os.path.join(root, "hooks/hooks.json")))
cmds = []
for ev, entries in (hj.get("hooks") or {}).items():
    for e in entries:
        for h in e.get("hooks") or []:
            cmds.append((ev, h.get("command", "")))
R("PASS" if len(cmds) == 2 else "FAIL", "hooks.json registers 2 hooks", "got %d" % len(cmds))
for ev, c in cmds:
    rel = c.replace("${CLAUDE_PLUGIN_ROOT}/", "")
    fp = os.path.join(root, rel)
    ok = os.path.isfile(fp) and os.access(fp, os.X_OK)
    R("PASS" if ok else "FAIL", "hooks.json %s -> %s" % (ev, rel), "missing or not executable")
print("__END__")
PY
consume "$TMP/reg.out"

# ------------------------------------------------------------ 7. guard hook --
sect "7. PreToolUse guard decisions"
GUARD="$ROOT/hooks/guard-openshell.sh"

guard_field() {  # $1 = payload file, $2 = decision|reason
  bash "$GUARD" < "$1" 2>/dev/null | FIELD="$2" python3 -c '
import json, os, sys
d = sys.stdin.read().strip()
if not d:
    print("allow" if os.environ["FIELD"] == "decision" else "")
    raise SystemExit
try:
    o = json.loads(d)["hookSpecificOutput"]
except Exception:
    print("MALFORMED_OUTPUT"); raise SystemExit
print(o.get("permissionDecision" if os.environ["FIELD"] == "decision" else
            "permissionDecisionReason", ""))'
}

while IFS=' ' read -r fx want; do
  [ -z "${fx:-}" ] && continue
  case "$fx" in \#*) continue ;; esac
  if [ ! -f "$FIX/$fx" ]; then fail "guard $fx" "fixture missing"; continue; fi
  got="$(guard_field "$FIX/$fx" decision)"
  chk "guard: $fx -> $want" "$want" "$got"
  if [ "$want" != "allow" ]; then
    reason="$(guard_field "$FIX/$fx" reason)"
    if [ ${#reason} -ge 40 ]; then pass "guard: $fx gives an actionable reason (${#reason} chars)"
    else fail "guard: $fx gives an actionable reason" "reason too short: [$reason]"; fi
  fi
done <<'CASES'
guard-insecure-deny.json deny
guard-delete-allworkspaces-deny.json deny
guard-env-secret-deny.json deny
guard-cred-argv-deny.json deny
guard-token-shaped-deny.json deny
guard-endpoint-ask.json ask
guard-endpoint-env-ask.json ask
guard-policy-global-ask.json ask
guard-workspace-delete-ask.json ask
guard-endpoint-full-ask.json ask
guard-gateway-remove-ask.json ask
guard-gateway-logout-ask.json ask
guard-unbalanced-quote-ask.json ask
guard-evasion-timeout-deny.json deny
guard-evasion-eval-deny.json deny
guard-evasion-stdbuf-deny.json deny
guard-evasion-nice-deny.json deny
guard-evasion-xargs-deny.json deny
guard-allow-ls.json allow
guard-allow-sandbox-list.json allow
guard-allow-scoped-delete.json allow
guard-allow-token-file.json allow
guard-allow-tokenizers-env.json allow
guard-allow-grep-word.json allow
CASES

# reason content: each new rule must say WHY, not just "denied"
r="$(guard_field "$FIX/guard-insecure-deny.json" reason)"
case "$r" in *TLS*) pass "guard: --gateway-insecure reason names TLS" ;;
  *) fail "guard: --gateway-insecure reason names TLS" "got: ${r:0:80}" ;; esac
r="$(guard_field "$FIX/guard-cred-argv-deny.json" reason)"
case "$r" in *--token-stdin*) pass "guard: credential-in-argv reason offers --token-stdin" ;;
  *) fail "guard: credential-in-argv reason offers --token-stdin" "got: ${r:0:80}" ;; esac
r="$(guard_field "$FIX/guard-gateway-remove-ask.json" reason)"
case "$r" in *one-time*) pass "guard: gateway remove reason warns the token is spent" ;;
  *) fail "guard: gateway remove reason warns the token is spent" "got: ${r:0:80}" ;; esac

# The guard and the audit hook both claim, in comments, to carry a byte-identical
# credential-name classifier. If they drift, a value one refuses is a value the
# other writes to disk in the clear.
python3 - "$ROOT" >"$TMP/cls.out" <<'CLS'
import os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)
GUARD_F = "hooks/guard-openshell.sh"
AUDIT_F = "hooks/audit-policy.sh"

def block(rel):
    t = open(os.path.join(root, rel), encoding="utf-8").read()
    i = t.index("CRED = {")
    j = t.index("for a, b in PAIRS))", i)
    return t[i:t.index("\n", j)]

def wrappers(rel):
    t = open(os.path.join(root, rel), encoding="utf-8").read()
    m = re.search(r"^WRAPPERS = \((.*?)\)", t, re.M | re.S)
    if not m:
        raise ValueError("WRAPPERS tuple not found in " + rel)
    return tuple(sorted(re.findall(r'"([^"]+)"', m.group(1))))

try:
    a = block(GUARD_F); b = block(AUDIT_F)
except ValueError as e:
    R("FAIL", "credential classifier is shared by both hooks", "block not found: %s" % e)
else:
    R("PASS" if a == b else "FAIL",
      "credential classifier is byte-identical in guard-openshell.sh and audit-policy.sh",
      "the two hooks have drifted")

# The guard decides what to refuse and the audit hook decides what to record.
# They resolve command wrappers with the same tuple. If it drifts, a command
# one of them sees through is a command the other is blind to -- which is
# exactly how the H-3 defect let `timeout <destructive>` lose BOTH the deny and
# the audit entry at once.
try:
    wg = wrappers(GUARD_F); wa = wrappers(AUDIT_F)
except ValueError as e:
    R("FAIL", "WRAPPERS tuple is shared by both hooks", str(e))
else:
    R("PASS" if wg == wa else "FAIL",
      "WRAPPERS tuple is identical in guard-openshell.sh and audit-policy.sh",
      "guard=%s audit=%s" % (",".join(wg), ",".join(wa)))
    need = {"env", "command", "nohup", "sudo", "time", "exec",
            "eval", "timeout", "stdbuf", "nice", "ionice", "watch", "xargs"}
    missing = sorted(need - set(wg))
    R("PASS" if not missing else "FAIL",
      "WRAPPERS covers every command prefix the guard must see through",
      "not resolved: %s" % ", ".join(missing))
print("__END__")
CLS
consume "$TMP/cls.out"

# fail-closed on malformed payloads (kept out of fixtures/ so every fixture is valid JSON)
printf '%s' '{"tool_input": {"command": "openshell sandbox delete --all' > "$TMP/mal-osh.json"
printf '%s' '{"tool_input": {"command": "ls -la' > "$TMP/mal-plain.json"
: > "$TMP/mal-empty.json"
chk "guard: malformed JSON mentioning the CLI -> ask" ask   "$(guard_field "$TMP/mal-osh.json" decision)"
chk "guard: malformed JSON with no CLI mention -> allow" allow "$(guard_field "$TMP/mal-plain.json" decision)"
chk "guard: empty payload -> allow" allow "$(guard_field "$TMP/mal-empty.json" decision)"

# fail-closed when python3 is unavailable
mkdir -p "$TMP/nopy"
for b in bash sh awk date cat tr sed grep head cut printf env; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$TMP/nopy/$b"
done
nopy_guard() { PATH="$TMP/nopy" bash "$GUARD" < "$1" 2>/dev/null; }
out="$(nopy_guard "$FIX/guard-allow-sandbox-list.json")"
case "$out" in *'"ask"'*) pass "guard: no python3 + CLI mention -> ask (fails closed)" ;;
  *) fail "guard: no python3 + CLI mention -> ask (fails closed)" "got: ${out:0:100}" ;; esac
out="$(nopy_guard "$FIX/guard-allow-ls.json")"
if [ -z "$out" ]; then pass "guard: no python3, unrelated command -> silent allow"
else fail "guard: no python3, unrelated command -> silent allow" "got: ${out:0:100}"; fi

# ------------------------------------------------------- 8. secret redaction --
sect "8. PostToolUse audit redaction"
AUDIT="$ROOT/hooks/audit-policy.sh"
NEEDLE="FAKE_SMOKE_TOKEN_0123456789_NOT_REAL"

audit_into() {  # $1 fixture, $2 logfile
  : > "$2"
  OPENSHELL_AUDIT_LOG="$2" CLAUDE_PROJECT_DIR="$TMP/never" \
    bash "$AUDIT" < "$1" >/dev/null 2>&1
}

redaction_case() {  # $1 fixture, $2 label, $3 expected-visible-substring
  local log="$TMP/audit-$2.log"
  audit_into "$FIX/$1" "$log"
  if grep -qF "$NEEDLE" "$log" 2>/dev/null; then
    fail "redaction [$2]: fake secret absent from log" "leaked: $(grep -F "$NEEDLE" "$log" | head -1)"
  else
    pass "redaction [$2]: fake secret absent from log"
  fi
  if [ -s "$log" ]; then pass "redaction [$2]: entry still recorded"
  else fail "redaction [$2]: entry still recorded" "log is empty -- the audit entry was dropped, not redacted"; fi
  if grep -qF '****' "$log" 2>/dev/null; then pass "redaction [$2]: value replaced with ****"
  else fail "redaction [$2]: value replaced with ****" "no mask in: $(head -1 "$log")"; fi
  if grep -qF -e "$3" "$log" 2>/dev/null; then pass "redaction [$2]: name '$3' still visible"
  else fail "redaction [$2]: name '$3' still visible" "got: $(head -1 "$log")"; fi
}

redaction_case audit-flag-space.json  flagspace '--api-key'
redaction_case audit-flag-eq.json     flageq    '--api-key=****'
redaction_case audit-var-assign.json  varassign 'MISSION_TOKEN=****'
redaction_case audit-unparsed.json    unparsed  'ACTIONBOARD_POD_TOKEN=****'

log="$TMP/audit-unparsed.log"
if grep -q 'UNPARSED' "$log"; then pass "redaction [unparsed]: took the UNPARSED path"
else fail "redaction [unparsed]: took the UNPARSED path" "got: $(head -1 "$log")"; fi

for pair in "audit-noop-ls.json:unrelated command" "audit-readonly.json:read-only sandbox list"; do
  fx="${pair%%:*}"; lbl="${pair#*:}"
  audit_into "$FIX/$fx" "$TMP/audit-quiet.log"
  if [ ! -s "$TMP/audit-quiet.log" ]; then pass "audit: $lbl writes no entry"
  else fail "audit: $lbl writes no entry" "wrote: $(head -1 "$TMP/audit-quiet.log")"; fi
done

# the awk fallback used when python3 is missing must redact too
for fx in audit-flag-space.json audit-unparsed.json; do
  log="$TMP/audit-nopy-$fx.log"
  : > "$log"
  PATH="$TMP/nopy" OPENSHELL_AUDIT_LOG="$log" CLAUDE_PROJECT_DIR="$TMP/never" \
    bash "$AUDIT" < "$FIX/$fx" >/dev/null 2>&1
  if grep -qF "$NEEDLE" "$log" 2>/dev/null; then
    fail "redaction [no-python3 $fx]: fake secret absent" "leaked: $(head -1 "$log")"
  else
    pass "redaction [no-python3 $fx]: fake secret absent"
  fi
  if [ -s "$log" ]; then pass "redaction [no-python3 $fx]: entry still recorded"
  else fail "redaction [no-python3 $fx]: entry still recorded" "log empty"; fi
done

# The real H-3 defect was that a command prefix hid a destructive verb from the
# guard AND from the audit log at the same time. A test that only checks the
# deny would pass while the paper trail stayed broken, so every evasion case is
# asserted on both sides. `sandbox delete` is in the audit hook's AUDITED set,
# so an entry is owed for all of these; the unwrapped baseline is the control
# that proves this assertion can fail.
sect "8b. H-3: deny and audit entry must survive the same wrapper"
for fx in guard-delete-allworkspaces-deny.json \
          guard-evasion-timeout-deny.json \
          guard-evasion-eval-deny.json \
          guard-evasion-stdbuf-deny.json \
          guard-evasion-nice-deny.json \
          guard-evasion-xargs-deny.json; do
  lbl="${fx#guard-}"; lbl="${lbl%-deny.json}"
  log="$TMP/pair-$lbl.log"
  audit_into "$FIX/$fx" "$log"
  if [ -s "$log" ]; then
    pass "audit trail survives [$lbl]: destructive verb still recorded"
  else
    fail "audit trail survives [$lbl]: destructive verb still recorded" \
         "no entry written -- this wrapper hides the command from the paper trail as well as from the guard"
  fi
done

# --------------------------------------------------------- 9. dry-run contract --
sect "9. --dry-run contract (stubbed CLI, no gateway, no network)"
mkdir -p "$TMP/bin"
STUB="$TMP/bin/openshell"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Throwaway stub. Answers only the two read-only calls a --dry-run legitimately
# needs and hard-fails on everything else, so a regression that lets a dry run
# reach a gateway surfaces as a failed check instead of a live API call.
printf '%s\n' "$*" >> "${STUB_CALL_LOG:-/dev/null}"
if [ "${1:-}" = "--version" ]; then echo "openshell 0.0.110"; exit 0; fi
if [ "${1:-}" = "gateway" ] && [ "${2:-}" = "list" ]; then
  if [ "${STUB_REMOTE:-0}" = "1" ]; then
    printf '%s\n' '[{"name":"actionboard-cloud","endpoint":"https://gw.smoke.invalid","auth":"oidc","type":"remote","is_remote":true,"active":true}]'
  else
    printf '%s\n' '[{"name":"smoke-local","endpoint":"unix:///dev/null","auth":"none","type":"local","is_remote":false,"active":true}]'
  fi
  exit 0
fi
echo "STUB REFUSED (the smoke suite must never reach a gateway): $*" >&2
exit 97
STUBEOF
chmod +x "$STUB"
printf 'version: 1\nfilesystem_policy:\n  include_workdir: true\nnetwork_policies: {}\n' > "$TMP/clean-policy.yaml"

CFG="$HOME/.config/openshell"
snap_cfg() {
  if [ ! -d "$CFG" ]; then echo "ABSENT"; return 0; fi
  find "$CFG" -type d 2>/dev/null | LC_ALL=C sort | sed 's/^/D /'
  find "$CFG" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
    printf 'F %s %s\n' "$(sha_of "$p")" "$p"
  done
}
snap_cfg > "$TMP/cfg.before"

CONNECT="$SCRIPTS/openshell-gateway-connect.sh"
PROVISION="$SCRIPTS/openshell-provision.sh"

run_connect() {  # $1 = out file, rest = args (token supplied via env by caller)
  local out="$1"; shift
  PATH="$TMP/bin:$PATH" bash "$CONNECT" "$@" >"$out" 2>&1
}

# 9a. env-token dry run
: > "$TMP/stub-connect.log"
STUB_CALL_LOG="$TMP/stub-connect.log" ACTIONBOARD_POD_TOKEN="$NEEDLE" \
  run_connect "$TMP/dr-connect.out" \
    --url https://gw.smoke.invalid --name smoke-gw \
    --oidc-issuer https://issuer.smoke.invalid \
    --oidc-audience smoke-aud --oidc-scopes "smoke:all" \
    --workspace smoke-ws --pod smoke-pod --dry-run
rc=$?
chk "connect --dry-run (env token) exits 0" 0 "$rc"
if grep -qF "$NEEDLE" "$TMP/dr-connect.out"; then
  fail "connect --dry-run leaks no token" "token text found in output"
else pass "connect --dry-run leaks no token"; fi
if grep -qF '****' "$TMP/dr-connect.out"; then pass "connect --dry-run masks the token as ****"
else fail "connect --dry-run masks the token as ****" "no mask in plan block"; fi
if grep -q 'nothing registered' "$TMP/dr-connect.out"; then pass "connect --dry-run states it registered nothing"
else fail "connect --dry-run states it registered nothing" "missing dry-run confirmation line"; fi
bad="$(grep -vE '^--version$' "$TMP/stub-connect.log" || true)"
if [ -z "$bad" ]; then pass "connect --dry-run called the CLI only for --version"
else fail "connect --dry-run called the CLI only for --version" "also called: $(echo "$bad" | tr '\n' ';')"; fi

# 9b. stdin-token dry run
: > "$TMP/stub-connect2.log"
printf '%s' "$NEEDLE" | STUB_CALL_LOG="$TMP/stub-connect2.log" PATH="$TMP/bin:$PATH" \
  bash "$CONNECT" --url https://gw.smoke.invalid --name smoke-gw \
    --oidc-issuer https://issuer.smoke.invalid --token-stdin --dry-run \
    >"$TMP/dr-connect2.out" 2>&1
rc=$?
chk "connect --dry-run (--token-stdin) exits 0" 0 "$rc"
if grep -qF "$NEEDLE" "$TMP/dr-connect2.out"; then
  fail "connect --token-stdin leaks no token" "token text found in output"
else pass "connect --token-stdin leaks no token"; fi

# 9c. argv secret refusal
PATH="$TMP/bin:$PATH" bash "$CONNECT" --url https://gw.smoke.invalid \
  --oidc-issuer https://issuer.smoke.invalid \
  --oidc-client-id FAKE0123456789ABCDEFfake0123456789ABCDEF --dry-run \
  >"$TMP/dr-refuse1.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "connect refuses a token-shaped argv value (exit $rc)"
else fail "connect refuses a token-shaped argv value" "exited 0"; fi
if grep -q 'ACTIONBOARD_POD_TOKEN' "$TMP/dr-refuse1.out"; then pass "connect refusal names the safe alternative"
else fail "connect refusal names the safe alternative" "$(head -2 "$TMP/dr-refuse1.out" | tr '\n' ' ')"; fi

PATH="$TMP/bin:$PATH" bash "$CONNECT" --url https://gw.smoke.invalid --client-secret nope --dry-run \
  >"$TMP/dr-refuse2.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "connect refuses a --client-secret flag (exit $rc)"
else fail "connect refuses a --client-secret flag" "exited 0"; fi

PATH="$TMP/bin:$PATH" ACTIONBOARD_POD_TOKEN="$NEEDLE" bash "$CONNECT" \
  --url http://gw.smoke.invalid --oidc-issuer https://issuer.smoke.invalid --dry-run \
  >"$TMP/dr-refuse3.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "connect refuses an http:// endpoint (exit $rc)"
else fail "connect refuses an http:// endpoint" "exited 0"; fi

PATH="$TMP/bin:$PATH" bash "$CONNECT" --url https://gw.smoke.invalid \
  --oidc-issuer https://issuer.smoke.invalid --dry-run >"$TMP/dr-refuse4.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "connect refuses to run with no token and no --browser (exit $rc)"
else fail "connect refuses to run with no token and no --browser" "exited 0"; fi

# 9d. provision dry run, local gateway
: > "$TMP/stub-prov.log"
STUB_CALL_LOG="$TMP/stub-prov.log" PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx-01 --gateway smoke-local \
  --workspace smoke-ws --dry-run >"$TMP/dr-prov.out" 2>&1
rc=$?
chk "provision --dry-run (local) exits 0" 0 "$rc"
bad="$(grep -vE '^gateway list --output json$' "$TMP/stub-prov.log" || true)"
if [ -z "$bad" ]; then pass "provision --dry-run called the CLI only for 'gateway list'"
else fail "provision --dry-run called the CLI only for 'gateway list'" "also called: $(echo "$bad" | tr '\n' ';')"; fi
if grep -q 'dry-run: nothing created' "$TMP/dr-prov.out"; then pass "provision --dry-run states it created nothing"
else fail "provision --dry-run states it created nothing" "missing confirmation line"; fi

# 9e. --agent-role emits the agent= label; --agent does not  (R2 regression guard)
STUB_CALL_LOG=/dev/null PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx-02 --gateway smoke-local \
  --agent-role yellow --policy "$TMP/clean-policy.yaml" --dry-run >"$TMP/dr-role.out" 2>&1
if grep -q -- '--label agent=yellow' "$TMP/dr-role.out"; then pass "provision: --agent-role yellow emits --label agent=yellow"
else fail "provision: --agent-role yellow emits --label agent=yellow" "$(grep -m1 'sandbox create' "$TMP/dr-role.out")"; fi
STUB_CALL_LOG=/dev/null PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx-03 --gateway smoke-local \
  --agent yellow --policy "$TMP/clean-policy.yaml" --dry-run >"$TMP/dr-agent.out" 2>&1
if grep -q -- '--label agent=yellow' "$TMP/dr-agent.out"; then
  fail "provision: --agent yellow does NOT set the agent= label" "it did -- the R2 doc fix would be wrong"
else pass "provision: --agent yellow does NOT set the agent= label"; fi
if grep -qE -- '-- +yellow' "$TMP/dr-agent.out"; then pass "provision: --agent yellow becomes the trailing sandbox command"
else fail "provision: --agent yellow becomes the trailing sandbox command" "$(grep -m1 'sandbox create' "$TMP/dr-agent.out")"; fi

# 9f. remote refusals
STUB_CALL_LOG=/dev/null STUB_REMOTE=1 PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase orchestrator --name smoke-sbx-04 --gateway actionboard-cloud --dry-run \
  >"$TMP/dr-replace.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "provision: remote + REPLACE_ placeholder is a hard failure (exit $rc)"
else fail "provision: remote + REPLACE_ placeholder is a hard failure" "exited 0"; fi
if grep -q 'REPLACE_' "$TMP/dr-replace.out"; then pass "provision: REPLACE_ refusal names the placeholder"
else fail "provision: REPLACE_ refusal names the placeholder" "$(head -2 "$TMP/dr-replace.out" | tr '\n' ' ')"; fi

STUB_CALL_LOG=/dev/null STUB_REMOTE=1 PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx-05 --gateway actionboard-cloud \
  --image ./localdir --policy "$TMP/clean-policy.yaml" --dry-run \
  >"$TMP/dr-image.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "provision: remote + local image build is a hard failure (exit $rc)"
else fail "provision: remote + local image build is a hard failure" "exited 0"; fi

STUB_CALL_LOG=/dev/null STUB_REMOTE=1 PATH="$TMP/bin:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx-06 --gateway actionboard-cloud \
  --policy "$TMP/clean-policy.yaml" --dry-run >"$TMP/dr-remote-ok.out" 2>&1
rc=$?
chk "provision: remote + resolved policy still dry-runs clean" 0 "$rc"

# 9g. teardown refuses an unnamed gateway for --delete
TEARDOWN="$SCRIPTS/openshell-teardown.sh"
env -u OPENSHELL_GATEWAY -u ACTIONBOARD_GATEWAY_NAME PATH="$TMP/bin:$PATH" STUB_CALL_LOG=/dev/null \
  bash "$TEARDOWN" --name smoke-sbx-01 --delete --yes >"$TMP/dr-teardown.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then pass "teardown: --delete without --gateway is refused (exit $rc)"
else fail "teardown: --delete without --gateway is refused" "exited 0"; fi
if grep -q -- '--gateway' "$TMP/dr-teardown.out"; then pass "teardown refusal names --gateway"
else fail "teardown refusal names --gateway" "$(head -2 "$TMP/dr-teardown.out" | tr '\n' ' ')"; fi

# 9i. full lifecycle against a second stub. These exercise the code paths AFTER
#     the dry-run gate -- the readiness loop and the teardown call -- which no
#     --dry-run reaches. Still a stub: no gateway, no network.
mkdir -p "$TMP/bin2"
cat > "$TMP/bin2/openshell" <<'ST2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALL_LOG:-/dev/null}"
case "$1" in
  --version) echo "openshell 0.0.110"; exit 0 ;;
  gateway)
    [ "$2" = "list" ] && { echo '[{"name":"smoke-local","is_remote":false,"active":true}]'; exit 0; }
    exit 0 ;;
  whoami)  echo '{"subject":"smoke-subject"}'; exit 0 ;;
  sandbox)
    case "$2" in
      create)   echo '{"name":"smoke-sbx"}'; exit 0 ;;
      get)      echo '{"phase":"Ready"}'; exit 0 ;;
      list)
        if [ "${STUB_LIST_EMPTY:-0}" = "1" ]; then echo '[]'
        else echo '[{"name":"smoke-sbx-a"},{"name":"smoke-sbx-b"}]'; fi
        exit 0 ;;
      stop|delete|download) exit 0 ;;
    esac
    exit 0 ;;
  service) exit 0 ;;
esac
exit 0
ST2
chmod +x "$TMP/bin2/openshell"

STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx --gateway smoke-local --timeout 8 \
  >"$TMP/full-prov-nows.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'sandbox ready' "$TMP/full-prov-nows.out"; then
  pass "provision with no --workspace reaches Ready"
else
  fail "provision with no --workspace reaches Ready" \
       "exit $rc; $(grep -iE 'unbound|timed out|error' "$TMP/full-prov-nows.out" | head -2 | tr '\n' ' ')"
fi

STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" bash "$PROVISION" \
  --usecase scratch --name smoke-sbx --gateway smoke-local --workspace smoke-ws --timeout 8 \
  >"$TMP/full-prov-ws.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q 'sandbox ready' "$TMP/full-prov-ws.out"; then
  pass "provision with --workspace reaches Ready (control)"
else
  fail "provision with --workspace reaches Ready (control)" "exit $rc"
fi

env -u OPENSHELL_GATEWAY -u ACTIONBOARD_GATEWAY_NAME -u OPENSHELL_WORKSPACE \
  STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" bash "$TEARDOWN" \
  --name smoke-sbx --stop >"$TMP/full-stop.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'unbound variable' "$TMP/full-stop.out"; then
  pass "teardown --stop with neither --workspace nor --gateway succeeds"
else
  fail "teardown --stop with neither --workspace nor --gateway succeeds" \
       "exit $rc; $(grep -iE 'unbound|error' "$TMP/full-stop.out" | head -1)"
fi

env -u OPENSHELL_WORKSPACE STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" bash "$TEARDOWN" \
  --name smoke-sbx --stop --gateway smoke-local >"$TMP/full-stop2.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "teardown --stop --gateway succeeds (control)"
else fail "teardown --stop --gateway succeeds (control)" "exit $rc"; fi

# 9j. bash 3.2 compatibility. /bin/bash on macOS is 3.2.57 and it is what
#     `#!/usr/bin/env bash` resolves to there for most users. Three constructs
#     that work on bash 5 fail on 3.2, and all three shipped: plain
#     "${arr[@]}" on an empty array under `set -u`, `mapfile`, and ${#arr[@]}
#     on an array that was never declared. A Linux CI running bash 5 sees none
#     of them, so these checks pin the old interpreter explicitly and SKIP
#     rather than silently pass when it is unavailable.
BASH32=""
for cand in /bin/bash /usr/bin/bash; do
  [ -x "$cand" ] || continue
  case "$("$cand" --version 2>/dev/null | head -1)" in
    *"version 3."*) BASH32="$cand"; break ;;
  esac
done

# Static: no bash-4-only construct anywhere in the shipped scripts.
python3 - "$ROOT" >"$TMP/b4.out" <<'B4'
import os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)

# Syntax that simply does not exist on bash 3.2.
BAD = [
    ("mapfile/readarray (bash 4.0)", re.compile(r"(?<![\w-])(mapfile|readarray)\s")),
    ("declare -A associative array (bash 4.0)", re.compile(r"declare\s+-A\b")),
    ("${var^^} / ${var,,} case conversion (bash 4.0)", re.compile(r"\$\{[A-Za-z_]\w*(\^\^|,,)")),
    ("&>> append-redirect (bash 4.0)", re.compile(r"&>>")),
    ("|& pipe-stderr (bash 4.0)", re.compile(r"\|&")),
]

# The empty-array trap, narrowed to the class that can actually bite.
# `"${A[@]}"` is only a bug when A can be EMPTY at that point: bash < 4.4
# raises "unbound variable" under `set -u`. An array initialised with
# elements (CMD=(openshell ...), GW_ARGS=(-g "$X")) can never be empty, so
# flagging it would just add noise-quoting. So: only arrays declared as a bare
# `A=()`, and only where no `${#A[@]}` size guard has already been made
# earlier in the file. The two safe spellings -- ${A[@]+"${A[@]}"} and
# "${A[@]:-}" -- do not match the expansion pattern.
EMPTY_DECL = re.compile(r"(?:^|;)\s*([A-Za-z_]\w*)=\(\)\s*(?=;|$)", re.M)
EXPAND = re.compile(r'(?<!\+)"\$\{([A-Za-z_]\w*)\[[@*]\]\}"')

hits = []
n = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".claude")]
    for fn in sorted(filenames):
        if not fn.endswith(".sh"):
            continue
        rel = os.path.relpath(os.path.join(dirpath, fn), root)
        if rel.startswith("tests/"):
            continue          # the suite runs under whatever bash the caller has
        n += 1
        txt = open(os.path.join(dirpath, fn), encoding="utf-8").read()
        lines = txt.splitlines()
        empties = set(EMPTY_DECL.findall(txt))
        guarded_at = {}
        for i, line in enumerate(lines, 1):
            for name in empties:
                if ("${#%s[@]}" % name) in line and name not in guarded_at:
                    guarded_at[name] = i
        for i, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                continue
            for label, rx in BAD:
                if rx.search(line):
                    hits.append("%s:%d %s -> %s" % (rel, i, label, line.strip()[:60]))
            for m in EXPAND.finditer(line):
                name = m.group(1)
                if name not in empties:
                    continue
                g = guarded_at.get(name)
                if g is not None and g < i:
                    continue
                hits.append('%s:%d unguarded "${%s[@]}" on an array declared empty '
                            '-- aborts under set -u on bash 3.2; use ${%s[@]+"${%s[@]}"}'
                            % (rel, i, name, name, name))

R("PASS" if n >= 5 else "FAIL", "scanned %d shipped scripts for bash-3.2 incompatibilities" % n, "")
R("PASS" if len(BAD) == 5 else "FAIL", "bash-4-only syntax ruleset is loaded (%d rules)" % len(BAD), "")
R("PASS" if not hits else "FAIL",
  "no bash-3.2 incompatibility in any shipped script", " | ".join(hits[:6]))
print("__END__")
B4
consume "$TMP/b4.out"

if [ -z "$BASH32" ]; then
  skip "bash 3.2 runtime checks" "no bash 3.x interpreter on this machine; static scan still ran"
else
  b32v="$("$BASH32" --version | head -1 | sed 's/.*version //;s/ .*//')"
  pass "found a bash 3.x interpreter for the compatibility checks ($BASH32, $b32v)"

  STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" "$BASH32" "$PROVISION" \
    --usecase scratch --name smoke-sbx --gateway smoke-local --timeout 8 \
    >"$TMP/b32-prov.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'sandbox ready' "$TMP/b32-prov.out"; then
    pass "bash 3.2: provision with no --workspace reaches Ready"
  else
    fail "bash 3.2: provision with no --workspace reaches Ready" \
         "exit $rc; $(grep -iE 'unbound|command not found|timed out' "$TMP/b32-prov.out" | head -1)"
  fi

  env -u OPENSHELL_GATEWAY -u ACTIONBOARD_GATEWAY_NAME -u OPENSHELL_WORKSPACE \
    STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" "$BASH32" "$TEARDOWN" \
    --name smoke-sbx --stop >"$TMP/b32-stop.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'unbound variable' "$TMP/b32-stop.out"; then
    pass "bash 3.2: teardown --stop with neither --workspace nor --gateway"
  else
    fail "bash 3.2: teardown --stop with neither --workspace nor --gateway" \
         "exit $rc; $(grep -iE 'unbound|command not found' "$TMP/b32-stop.out" | head -1)"
  fi

  # --selector: dead on 3.2 before the fix, because mapfile exits 127 there.
  env -u OPENSHELL_GATEWAY -u ACTIONBOARD_GATEWAY_NAME -u OPENSHELL_WORKSPACE \
    STUB_CALL_LOG=/dev/null PATH="$TMP/bin2:$PATH" "$BASH32" "$TEARDOWN" \
    --selector mission=smoke --stop >"$TMP/b32-sel.out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then pass "bash 3.2: teardown --selector resolves targets"
  else fail "bash 3.2: teardown --selector resolves targets" \
            "exit $rc; $(grep -iE 'unbound|command not found|no sandboxes' "$TMP/b32-sel.out" | head -1)"; fi
  if grep -q 'targets: smoke-sbx-a smoke-sbx-b' "$TMP/b32-sel.out"; then
    pass "bash 3.2: teardown --selector targets both matched sandboxes"
  else
    fail "bash 3.2: teardown --selector targets both matched sandboxes" \
         "$(grep -m1 'targets:' "$TMP/b32-sel.out")"
  fi

  # selector matching nothing: must be the honest error, not `TARGETS: unbound`.
  env -u OPENSHELL_GATEWAY -u ACTIONBOARD_GATEWAY_NAME -u OPENSHELL_WORKSPACE \
    STUB_CALL_LOG=/dev/null STUB_LIST_EMPTY=1 PATH="$TMP/bin2:$PATH" "$BASH32" "$TEARDOWN" \
    --selector mission=nothing --stop >"$TMP/b32-sel0.out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'no sandboxes matched' "$TMP/b32-sel0.out"; then
    pass "bash 3.2: teardown --selector with no match fails with a real message"
  else
    fail "bash 3.2: teardown --selector with no match fails with a real message" \
         "exit $rc; $(grep -iE 'unbound|command not found' "$TMP/b32-sel0.out" | head -1)"
  fi

  # the two --dry-run wrappers must also parse and run on 3.2
  STUB_CALL_LOG=/dev/null PATH="$TMP/bin:$PATH" ACTIONBOARD_POD_TOKEN="$NEEDLE" "$BASH32" "$CONNECT" \
    --url https://gw.smoke.invalid --oidc-issuer https://issuer.smoke.invalid --dry-run \
    >"$TMP/b32-connect.out" 2>&1
  rc=$?
  chk "bash 3.2: connect --dry-run exits 0" 0 "$rc"
  STUB_CALL_LOG=/dev/null PATH="$TMP/bin:$PATH" "$BASH32" "$PROVISION" \
    --usecase scratch --name smoke-sbx-b32 --gateway smoke-local --dry-run \
    >"$TMP/b32-provdry.out" 2>&1
  rc=$?
  chk "bash 3.2: provision --dry-run exits 0" 0 "$rc"
fi

# 9h. nothing under the real CLI config dir moved
snap_cfg > "$TMP/cfg.after"
if diff -q "$TMP/cfg.before" "$TMP/cfg.after" >/dev/null 2>&1; then
  pass "$CFG is byte-identical before and after the suite"
else
  fail "$CFG is byte-identical before and after the suite" "$(diff "$TMP/cfg.before" "$TMP/cfg.after" | head -5 | tr '\n' ' ')"
fi

# -------------------------------------------------------- 10. no secrets ----
sect "10. no credential-shaped values in the repository"
python3 - "$ROOT" >"$TMP/sec.out" <<'PY'
import os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)

# Built by concatenation so this file is not itself a hit for its own scanner.
NEEDLE = "SUPERSECRET" + "VALUE123"

SKIP_DIRS = {".git", ".claude", "node_modules", "__pycache__", ".DS_Store"}
# The audit log is gitignored, machine-local and never shipped; it records
# command text by design, so scanning it would report the operator's own shell
# history as a repository secret.
SKIP_FILES = {".openshell-audit.log", ".DS_Store"}

OBVIOUS_FAKE = ("FAKE", "EXAMPLE", "REPLACE_", "NOT_REAL", "SMOKE", "PLACEHOLDER",
                "****", "xxx", "XXX", "<", "${", "your-", "paste", "one-time token",
                "TODO", "CHANGEME", "dummy")

PATTERNS = [
    ("the fake token that leaked once this mission", re.compile(re.escape(NEEDLE))),
    ("AWS access key id",        re.compile(r"AKIA[0-9A-Z]{16}")),
    ("PEM private key block",    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("GitHub token",             re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}")),
    ("GitHub fine-grained PAT",  re.compile(r"github_pat_[A-Za-z0-9_]{30,}")),
    ("Slack token",              re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("JWT",                      re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("Google API key",           re.compile(r"AIza[0-9A-Za-z_-]{35}")),
]
GENERIC = re.compile(
    r"(?i)\b(secret|token|password|passwd|client[_-]?secret|api[_-]?key|access[_-]?key)"
    r"\s*[:=]\s*[\"']?([A-Za-z0-9/+=_.-]{20,})")

hits = []
scanned = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if fn in SKIP_FILES:
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        try:
            txt = open(p, encoding="utf-8", errors="strict").read()
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for lineno, line in enumerate(txt.splitlines(), 1):
            for label, rx in PATTERNS:
                m = rx.search(line)
                if m:
                    hits.append("%s:%d %s -> %s" % (rel, lineno, label, m.group(0)[:40]))
            m = GENERIC.search(line)
            if m:
                val = m.group(2)
                if not any(f in val for f in OBVIOUS_FAKE) and not any(f in line for f in OBVIOUS_FAKE):
                    hits.append("%s:%d credential-shaped assignment -> %s" % (rel, lineno, val[:40]))

R("PASS" if scanned >= 40 else "FAIL", "scanned %d text files" % scanned, "too few files scanned")
R("PASS" if not hits else "FAIL", "no credential-shaped value in the repository",
  " | ".join(hits[:6]))
R("PASS" if NEEDLE not in open(os.path.join(root, "tests/smoke.sh"),
                               encoding="utf-8").read() else "FAIL",
  "the smoke suite does not itself embed the leaked fake token", "")
print("__END__")
PY
consume "$TMP/sec.out"

# --------------------------------------------- 11. docs match the code ------
sect "11. docs vs code"
python3 - "$ROOT" >"$TMP/doc.out" <<'PY'
import os, re, sys
root = sys.argv[1]; T = "\t"
def R(st, nm, det=""): print(st + T + nm + T + det)

SCRIPTS = os.path.join(root, "skills/openshell-admin/scripts")
WRAPPERS = {}
for fn in os.listdir(SCRIPTS):
    if not fn.endswith(".sh"):
        continue
    txt = open(os.path.join(SCRIPTS, fn), encoding="utf-8").read()
    flags = set()
    for m in re.finditer(r"^\s{2,}((?:-{1,2}[A-Za-z0-9][\w-]*)(?:\|-{1,2}[A-Za-z0-9][\w-]*)*)\)",
                         txt, re.M):
        for f in m.group(1).split("|"):
            flags.add(f)
    WRAPPERS[fn] = flags
    R("PASS" if len(flags) >= 8 else "FAIL",
      "parsed %d accepted flags from %s" % (len(flags), fn), "arg parser not recognised")

def snippets(rel, txt):
    """Yield text fragments that look like a shell invocation."""
    if rel.endswith((".md", ".html")):
        for m in re.finditer(r"```[a-z]*\n(.*?)```", txt, re.S):
            yield m.group(1)
        for m in re.finditer(r"<pre><code>(.*?)</code></pre>", txt, re.S):
            yield m.group(1)
        for m in re.finditer(r"`([^`\n]+)`", txt):
            yield m.group(1)
    else:
        lines = txt.splitlines()
        i = 0
        while i < len(lines):
            buf = lines[i]
            while buf.rstrip().endswith("\\") and i + 1 < len(lines):
                i += 1
                buf = buf.rstrip()[:-1] + " " + lines[i]
            yield buf
            i += 1

SCAN_EXT = (".md", ".html", ".sh", ".yaml", ".yml")
bad = []
checked = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".claude", "tests")]
    for fn in filenames:
        if not fn.endswith(SCAN_EXT):
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        try:
            txt = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for sn in snippets(rel, txt):
            named = [w for w in WRAPPERS if w in sn]
            if not named:
                continue
            allowed = set()
            for w in named:
                allowed |= WRAPPERS[w]
            for f in set(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", sn)):
                checked += 1
                if f not in allowed:
                    bad.append("%s: %s passes %s (accepted: %s)"
                               % (rel, "/".join(named), f, ", ".join(sorted(allowed))))
R("PASS" if checked >= 30 else "FAIL",
  "checked %d wrapper flag mentions across the docs and scripts" % checked, "too few")
R("PASS" if not bad else "FAIL", "every wrapper flag used in docs is accepted by that wrapper",
  " | ".join(sorted(set(bad))[:6]))

# R2's correction, enforced: no file may pass an agent ROLE to --agent.
ROLES = ("black", "green", "blue", "yellow", "red")
rx = re.compile(r"--agent\s+(%s)\b" % "|".join(ROLES))
role_bad = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in (".git", ".claude", "tests")]
    for fn in filenames:
        if not fn.endswith(SCAN_EXT):
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root)
        try:
            txt = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(txt.splitlines(), 1):
            if rx.search(line):
                role_bad.append("%s:%d %s" % (rel, i, line.strip()[:70]))
R("PASS" if not role_bad else "FAIL",
  "no file passes an agent role to --agent (it is --agent-role)", " | ".join(role_bad[:4]))

# Every /slash-command named in the docs resolves to a shipped skill or command.
# Candidates are code spans (or whole lines) that START with a slash and are a
# bare single-segment token -- that excludes HTTP paths like `GET /health`,
# closing HTML tags, and filesystem paths with a second slash.
BUILTIN = {"/plugin", "/reload-plugins", "/graphify", "/clear", "/help", "/doctor",
           "/mcp", "/agents", "/hooks", "/config", "/raoara"}
FS_PATHS = {"/tmp", "/usr", "/lib", "/etc", "/var", "/bin", "/opt", "/dev", "/proc",
            "/sys", "/home", "/root", "/sandbox", "/workspace", "/output", "/mnt"}
skills = {"/" + d for d in os.listdir(os.path.join(root, "skills"))
          if os.path.isdir(os.path.join(root, "skills", d))}
cmds = {"/" + f[:-3] for f in os.listdir(os.path.join(root, "commands")) if f.endswith(".md")}
known = BUILTIN | skills | cmds
unknown = []
n_slash = 0
doc_files = ["README.md", "docs/index.html", "commands/start-mission.md"] + \
    ["skills/%s/SKILL.md" % d for d in sorted(os.listdir(os.path.join(root, "skills")))
     if os.path.isdir(os.path.join(root, "skills", d))] + \
    ["agents/%s" % f for f in sorted(os.listdir(os.path.join(root, "agents")))]
for rel in doc_files:
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        continue
    txt = open(p, encoding="utf-8").read()
    spans = re.findall(r"`([^`\n]+)`", txt) + re.findall(r"<code>([^<]*)</code>", txt, re.S)
    spans += [ln for ln in txt.splitlines() if ln.startswith("/")]
    for sp in spans:
        sp = sp.strip()
        if not sp.startswith("/"):
            continue
        tok = sp.split()[0].rstrip(".,;:)")
        if not re.match(r"^/[a-z][a-z0-9-]*$", tok) or tok in FS_PATHS:
            continue
        n_slash += 1
        if tok not in known:
            unknown.append("%s -> %s" % (rel, tok))
R("PASS" if n_slash >= 25 else "FAIL",
  "found %d slash-command references in the docs" % n_slash, "too few to be a real check")
R("PASS" if not unknown else "FAIL", "every slash command in the docs resolves",
  " | ".join(sorted(set(unknown))[:8]))

# Coverage the other way: every user-invocable skill is reachable from the docs.
allslash = set()
for rel in doc_files:
    p = os.path.join(root, rel)
    if os.path.isfile(p):
        allslash |= set(re.findall(r"(?<![\w/.-])(/[a-z][a-z0-9-]*)\b",
                                   open(p, encoding="utf-8").read()))
undoc = []
for d in sorted(skills):
    sp = os.path.join(root, "skills", d[1:], "SKILL.md")
    if not os.path.isfile(sp):
        continue
    fm = open(sp, encoding="utf-8").read()[:1200]
    if "user-invocable: false" in fm:
        continue
    if d not in allslash and "`%s`" % d[1:] not in open(os.path.join(root, "README.md"),
                                                        encoding="utf-8").read():
        undoc.append(d)
R("PASS" if not undoc else "FAIL", "every user-invocable skill is named in the docs",
  ", ".join(undoc))

# docs/index.html advertises the real skill and agent counts
html = open(os.path.join(root, "docs/index.html"), encoding="utf-8").read()
n_sk = len([d for d in os.listdir(os.path.join(root, "skills"))
            if os.path.isdir(os.path.join(root, "skills", d))])
# sandbox-warden is a forked subagent, not one of the five formation agents the
# docs count; every other agents/*.md is one of the five.
ALL_AGENTS = [f[:-3] for f in os.listdir(os.path.join(root, "agents")) if f.endswith(".md")]
n_ag = len([a for a in ALL_AGENTS if a != "sandbox-warden"])
R("PASS" if "sandbox-warden" in ALL_AGENTS else "FAIL",
  "agents/sandbox-warden.md exists (the harness fork target)", "")
for claimed_sk, claimed_ag in re.findall(r"(\d+)\s+skills?[^\d]{0,4}(\d+)\s+agents?", html):
    R("PASS" if (int(claimed_sk), int(claimed_ag)) == (n_sk, n_ag) else "FAIL",
      "docs/index.html claims %s skills / %s agents" % (claimed_sk, claimed_ag),
      "repository has %d skills / %d agents" % (n_sk, n_ag))

# README's skill table must list every user-invocable skill
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
missing = []
for d in sorted(os.listdir(os.path.join(root, "skills"))):
    sp = os.path.join(root, "skills", d, "SKILL.md")
    if not os.path.isfile(sp):
        continue
    if "user-invocable: false" in open(sp, encoding="utf-8").read():
        pass
    if "`%s`" % d not in readme:
        missing.append(d)
R("PASS" if not missing else "FAIL", "README names every shipped skill",
  "not mentioned: %s" % ", ".join(missing))
print("__END__")
PY
consume "$TMP/doc.out"

# ----------------------------------------------------------- 12. summary ----
sect "summary"
if [ ! -f "$AUDIT_LOG" ]; then
  if [ "$AUDIT_SIZE_BEFORE" -eq 0 ]; then
    pass "repo-root .openshell-audit.log still absent"
    pass "no suite content reached the repo-root audit log (file absent)"
  else
    fail "repo-root .openshell-audit.log was not deleted" "it existed at start and is gone"
    fail "no suite content reached the repo-root audit log" "file disappeared mid-run"
  fi
else
  # 1. append-only: the bytes that were there at the start are still there,
  #    byte for byte. This catches a truncation or rewrite regardless of who
  #    else appended while we ran.
  head -c "$AUDIT_SIZE_BEFORE" "$AUDIT_LOG" > "$TMP/audit.prefix" 2>/dev/null || true
  if cmp -s "$TMP/audit.before" "$TMP/audit.prefix"; then
    pass "repo-root .openshell-audit.log was appended to, never rewritten or truncated"
  else
    fail "repo-root .openshell-audit.log was appended to, never rewritten or truncated" \
         "the first $AUDIT_SIZE_BEFORE bytes changed"
  fi

  # 2. nothing the suite produced is in the delta. Concurrent activity from
  #    another agent or session is expected and reported, not failed.
  tail -c "+$((AUDIT_SIZE_BEFORE + 1))" "$AUDIT_LOG" > "$TMP/audit.delta" 2>/dev/null || : > "$TMP/audit.delta"
  delta_lines="$(wc -l < "$TMP/audit.delta" | tr -d ' ')"
  mine=""
  for marker in "$NEEDLE" "$TMP" "smoke-sbx" "smoke-gw" "smoke-ws" "smoke-pod" \
                "smoke-local" "smoke-aud" "ab-smoke." "FAKE_SMOKE"; do
    if grep -qF -e "$marker" "$TMP/audit.delta" 2>/dev/null; then
      mine="$mine $marker"
    fi
  done
  if [ -z "$mine" ]; then
    if [ "$delta_lines" -eq 0 ]; then
      pass "no suite content reached the repo-root audit log (log unchanged)"
    else
      pass "no suite content reached the repo-root audit log ($delta_lines line(s) appended by concurrent activity, none ours)"
    fi
  else
    fail "no suite content reached the repo-root audit log" \
         "suite markers found in the appended lines:$mine"
  fi
fi

TOTAL=$((N_PASS + N_FAIL + N_SKIP))
printf '\n%s\n' "------------------------------------------------------------"
printf '%d checks run: %d passed, %d failed, %d skipped\n' "$TOTAL" "$N_PASS" "$N_FAIL" "$N_SKIP"
if [ "$N_FAIL" -ne 0 ]; then
  printf 'failed:%s\n' "$FAILED"
  printf '%s\n' "------------------------------------------------------------"
  exit 1
fi
printf '%s\n' "------------------------------------------------------------"
exit 0
