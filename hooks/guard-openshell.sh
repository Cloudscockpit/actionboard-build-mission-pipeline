#!/usr/bin/env bash
# PreToolUse guard: blocks blast-radius OpenShell commands before they run.
#
# Reads the tool call as JSON on stdin and emits a PreToolUse permission
# decision. Anything it does not recognise passes through untouched.
#
# The command is parsed into argv with shlex rather than substring-matched.
# The shell strips quotes before the CLI ever sees them, so a guard that greps
# for --all-workspaces misses --all-work"spaces", which runs identically.
# Parsing also covers --flag=value, short flags, extra whitespace, operator
# chains, `bash -c` wrappers, and leading VAR=value assignments.
#
# Fails CLOSED: if the payload mentions openshell but cannot be parsed --
# malformed JSON, unbalanced quotes, or a missing python3 -- it asks for human
# review rather than allowing the command through unchecked.

set -uo pipefail
payload="$(cat)"

# Pure-bash emitter, so a decision can still be returned without python3.
emit() {
  local dec="$1" reason="${2//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$dec" "$reason"
  exit 0
}

if ! command -v python3 >/dev/null 2>&1; then
  case "$payload" in
    *openshell*) emit ask "The OpenShell guard could not run (python3 is unavailable) and this command mentions openshell. Review it manually before allowing." ;;
    *) exit 0 ;;
  esac
fi

result="$(printf '%s' "$payload" | python3 -c '
import json, re, shlex, sys

CRED = {"TOKEN","SECRET","PASSWORD","PASSWD","CREDENTIAL","CREDENTIALS","KEY",
        "APIKEY","PAT","AUTH","PRIVATE","CERT","SESSION","SIGNATURE","BEARER"}
PAIRS = {("API","KEY"),("ACCESS","KEY"),("SECRET","KEY"),("PRIVATE","KEY"),
         ("REFRESH","TOKEN"),("ACCESS","TOKEN"),("CLIENT","SECRET")}
SPLIT = re.compile(r"&&|\|\||;|\||\n")
WRAPPERS = ("env", "command", "nohup", "sudo", "time", "exec")


def out(decision, reason=""):
    print(json.dumps({"decision": decision, "reason": reason}))
    sys.exit(0)


data = sys.stdin.read()
try:
    payload = json.loads(data)
except Exception:
    # Only fail closed when the unparseable payload is plausibly ours. A
    # malformed payload with no mention of openshell cannot be an openshell
    # command, so blocking it would be a false positive on every other tool.
    if "openshell" in data:
        out("parse_error")
    sys.exit(0)

raw = (payload.get("tool_input") or {}).get("command", "") or ""
if "openshell" not in raw:
    sys.exit(0)


def invocations(text, depth=0):
    """Yield the argv tail of every openshell invocation inside a command."""
    if depth > 3:
        return
    for part in SPLIT.split(text):
        part = part.strip()
        if not part:
            continue
        argv = shlex.split(part)          # ValueError on unbalanced quotes
        while argv:
            head = argv[0]
            if not head.startswith("-") and "=" in head:
                argv = argv[1:]           # VAR=value prefix
                continue
            if head in WRAPPERS:
                argv = argv[1:]
                continue
            if head in ("bash", "sh", "zsh") and "-c" in argv:
                i = argv.index("-c")
                if i + 1 < len(argv):
                    yield from invocations(argv[i + 1], depth + 1)
                argv = []
                continue
            break
        if argv and argv[0].rsplit("/", 1)[-1] == "openshell":
            yield argv[1:]


def flags(argv):
    """Yield (name, value) for --flag=v, --flag v, -f=v and -f v."""
    i = 0
    while i < len(argv):
        tok = argv[i]
        if tok.startswith("-"):
            if "=" in tok:
                name, value = tok.split("=", 1)
                yield name, value
            else:
                nxt = argv[i + 1] if i + 1 < len(argv) else ""
                if nxt and not nxt.startswith("-"):
                    yield tok, nxt
                    i += 1
                else:
                    yield tok, ""
        i += 1


def credential_like(name):
    segs = re.split(r"[_\-]", name.upper())
    return (any(s in CRED for s in segs)
            or any(a in segs and b in segs for a, b in PAIRS))


try:
    calls = list(invocations(raw))
except ValueError:
    out("parse_error")

for argv in calls:
    positional = [a for a in argv if not a.startswith("-")]
    verb = " ".join(positional[:2]).lower()
    pairs = list(flags(argv))
    names = {n for n, _ in pairs}

    # 1. Cross-workspace destruction: can empty a tenant never part of this mission.
    if verb == "sandbox delete" and ({"--all-workspaces", "--all"} & names):
        out("deny", "Refusing a cross-workspace sandbox delete. Target one "
                    "workspace with --workspace, or delete by explicit name.")

    # 2. Global policy: while one exists, per-sandbox policy updates are rejected.
    if verb == "policy set" and "--global" in names:
        out("ask", "This sets a platform-wide policy. While it is active, all "
                   "sandbox-level policy updates are rejected until it is deleted. "
                   "Confirm this is a deliberate baseline change.")

    # 3. Workspace deletion.
    if verb == "workspace delete":
        out("ask", "Deleting a workspace removes its membership records and "
                   "inference routes. Confirm the workspace is empty and that "
                   "this is intended.")

    # 4. Credential-shaped plain environment values. Segment-matched, so
    #    TOKENIZERS_PARALLELISM and PASSWORDLESS_LOGIN do not trip it.
    if verb in ("sandbox create", "sandbox update"):
        for name, value in pairs:
            if name in ("--env", "-e") and "=" in value:
                var = value.split("=", 1)[0]
                if credential_like(var):
                    out("deny", "--env %s looks like a credential, and the "
                                "sandboxed agent can read plain environment values "
                                "directly. Attach it with --provider so the gateway "
                                "injects it at the network boundary." % var)

    # 5. access: full on an endpoint.
    for name, value in pairs:
        if name == "--add-endpoint" and value.endswith(":full"):
            out("ask", "This grants access: full on an endpoint. Prefer read-only "
                       "or read-write plus explicit method/path rules. Confirm full "
                       "access is required.")
' 2>/dev/null)"

[[ -z "$result" ]] && exit 0     # parser found nothing to decide on

decision="$(printf '%s' "$result" | python3 -c \
  'import json,sys;print(json.load(sys.stdin).get("decision",""))' 2>/dev/null)"

case "$decision" in
  parse_error)
    emit ask "This command mentions openshell but could not be parsed (malformed payload or unbalanced quotes), so the guard could not evaluate it. Review it manually before allowing."
    ;;
  deny|ask)
    reason="$(printf '%s' "$result" | python3 -c \
      'import json,sys;print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)"
    emit "$decision" "$reason"
    ;;
esac
exit 0
