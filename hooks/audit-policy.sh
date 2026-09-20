#!/usr/bin/env bash
# PostToolUse: append every OpenShell policy mutation to a local audit log.
# Yellow Agent reads this; it is also the paper trail when a grant is questioned later.
# Never blocks and never fails the tool call.

set -uo pipefail

LOG="${OPENSHELL_AUDIT_LOG:-${CLAUDE_PROJECT_DIR:-.}/.openshell-audit.log}"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
print((d.get("tool_input") or {}).get("command", ""))
' 2>/dev/null)"

case "$cmd" in
  *"openshell policy "*|*"openshell sandbox create"*|*"openshell sandbox delete"*|*"openshell provider "*)
    printf '%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${CLAUDE_SESSION_ID:-nosession}" \
      "$cmd" >> "$LOG" 2>/dev/null || true
    ;;
esac

exit 0
