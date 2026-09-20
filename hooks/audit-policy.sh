#!/usr/bin/env bash
# PostToolUse: append every OpenShell state mutation to a local audit log.
# Yellow Agent reads this; it is also the paper trail when a grant is questioned later.
# Never blocks and never fails the tool call.
#
# Matching mirrors guard-openshell.sh: the command is parsed into argv with
# shlex, not substring-matched, so `openshell  policy set` (extra whitespace),
# `bash -c "openshell ..."`, and chained commands are all still recorded.
#
# Coverage is deliberately wider than the guard's. The guard only stops what is
# dangerous; the log records everything that CHANGES state, including actions
# the guard merely asks about -- an approved destructive action with no audit
# entry is the gap that makes the trail untrustworthy.

set -uo pipefail

LOG="${OPENSHELL_AUDIT_LOG:-${CLAUDE_PROJECT_DIR:-.}/.openshell-audit.log}"
payload="$(cat)"

command -v python3 >/dev/null 2>&1 || {
  # Cannot parse; record the raw command rather than silently dropping it.
  case "$payload" in
    *openshell*)
      printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${CLAUDE_SESSION_ID:-nosession}" "UNPARSED" "$payload" >> "$LOG" 2>/dev/null || true
      ;;
  esac
  exit 0
}

entries="$(printf '%s' "$payload" | python3 -c '
import json, re, shlex, sys

SPLIT = re.compile(r"&&|\|\||;|\||\n")
WRAPPERS = ("env", "command", "nohup", "sudo", "time", "exec")

# Verbs that mutate durable state. sandbox update is included because it can
# change a sandbox policy; workspace create/delete because the guard only asks
# about deletion, so without this the approved action leaves no trace.
AUDITED = {
    "policy",                                   # any policy subcommand
    "provider",                                 # any provider subcommand
    "sandbox create", "sandbox delete", "sandbox update", "sandbox exec",
    "workspace create", "workspace delete", "workspace update",
}

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

raw = (payload.get("tool_input") or {}).get("command", "") or ""
if "openshell" not in raw:
    sys.exit(0)


def invocations(text, depth=0):
    if depth > 3:
        return
    for part in SPLIT.split(text):
        part = part.strip()
        if not part:
            continue
        try:
            argv = shlex.split(part)
        except ValueError:
            yield ("UNPARSED", part)
            continue
        while argv:
            head = argv[0]
            if not head.startswith("-") and "=" in head:
                argv = argv[1:]; continue
            if head in WRAPPERS:
                argv = argv[1:]; continue
            if head in ("bash", "sh", "zsh") and "-c" in argv:
                i = argv.index("-c")
                if i + 1 < len(argv):
                    yield from invocations(argv[i + 1], depth + 1)
                argv = []; continue
            break
        if argv and argv[0].rsplit("/", 1)[-1] == "openshell":
            yield ("CALL", argv)


for kind, item in invocations(raw):
    if kind == "UNPARSED":
        print("UNPARSED\t" + item.replace("\t", " "))
        continue
    argv = item
    positional = [a for a in argv[1:] if not a.startswith("-")]
    group = positional[0].lower() if positional else ""
    verb = " ".join(positional[:2]).lower()
    if group in AUDITED or verb in AUDITED:
        print((verb or group) + "\t" + " ".join(shlex.quote(a) for a in argv).replace("\t", " "))
' 2>/dev/null)"

[[ -z "$entries" ]] && exit 0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf '%s\t%s\t%s\n' "$ts" "${CLAUDE_SESSION_ID:-nosession}" "$line" >> "$LOG" 2>/dev/null || true
done <<< "$entries"

exit 0
