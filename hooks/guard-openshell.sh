#!/usr/bin/env bash
# PreToolUse guard: blocks blast-radius OpenShell commands before they run.
# Reads the tool call as JSON on stdin, emits a PreToolUse permission decision.
# Everything it does not recognize passes through untouched.

set -uo pipefail

payload="$(cat)"

cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print((d.get("tool_input") or {}).get("command", ""))
' 2>/dev/null)"

[[ -z "$cmd" ]] && exit 0
[[ "$cmd" != *openshell* ]] && exit 0

deny() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": sys.argv[1]
  }
}))
PY
  exit 0
}

ask() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": sys.argv[1]
  }
}))
PY
  exit 0
}

# 1. Cross-workspace destruction. A selector plus --all-workspaces can empty a
#    tenant that was never part of this mission.
if [[ "$cmd" == *"sandbox delete"* && "$cmd" == *"--all-workspaces"* ]]; then
  deny "Refusing a cross-workspace sandbox delete. Target one workspace with --workspace, or delete by explicit name."
fi

# 2. Global policy. While one exists, every per-sandbox policy update is rejected.
if [[ "$cmd" == *"policy set"* && "$cmd" == *"--global"* ]]; then
  ask "This sets a platform-wide policy. While it is active, all sandbox-level policy updates are rejected until it is deleted. Confirm this is a deliberate baseline change."
fi

# 3. Workspace deletion.
if [[ "$cmd" == *"workspace delete"* ]]; then
  ask "Deleting a workspace removes its membership records and inference routes. Confirm the workspace is empty and that this is intended."
fi

# 4. Credential-shaped values passed as plain environment variables.
#    Matched on whole underscore-separated segments, as OpenShell does, so
#    TOKENIZERS_PARALLELISM and PASSWORDLESS_LOGIN do not trip it.
if [[ "$cmd" == *"sandbox create"* ]]; then
  hit="$(printf '%s' "$cmd" | python3 -c '
import re, sys
CRED = {"TOKEN","SECRET","PASSWORD","CREDENTIAL","CREDENTIALS","KEY","APIKEY"}
PAIRS = {("API","KEY"),("ACCESS","KEY"),("SECRET","KEY")}
cmd = sys.stdin.read()
for name in re.findall(r"--env[ =]([A-Za-z_][A-Za-z0-9_]*)=", cmd):
    segs = name.upper().split("_")
    if any(s in CRED for s in segs) or any(a in segs and b in segs for a, b in PAIRS):
        print(name); break
')"
  if [[ -n "$hit" ]]; then
    deny "--env $hit looks like a credential, and the sandboxed agent can read plain environment values directly. Attach it with --provider so the gateway injects it at the network boundary."
  fi
fi

# 5. access: full on a new endpoint.
if [[ "$cmd" == *"policy update"* ]] && printf '%s' "$cmd" | grep -q -- '--add-endpoint [^ ]*:full'; then
  ask "This grants access: full on an endpoint. Prefer read-only or read-write plus explicit method/path rules. Confirm full access is required."
fi

exit 0
