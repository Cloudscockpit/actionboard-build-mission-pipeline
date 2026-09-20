#!/usr/bin/env bash
# openshell-provision.sh — usecase-driven OpenShell sandbox provisioning.
#
# Resolves a profile into a sandbox spec, renders its policy template, creates
# the sandbox, and blocks until the gateway reports phase=Ready.
#
#   ./openshell-provision.sh --usecase data --name green-ingest-01 \
#       --workspace tenant-acme --tenant acme --pod acme-prod --mission m-4471
#
# Always run with --dry-run first and show the plan before creating anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${OPENSHELL_POLICY_DIR:-$SCRIPT_DIR/../policies}"

USECASE=""; NAME=""; WORKSPACE=""; GATEWAY=""; AGENT=""
IMAGE=""; CPU=""; MEMORY=""; GPU=""; POLICY=""
TENANT=""; POD=""; MISSION=""; AGENT_ROLE=""
DRY_RUN=0; KEEP=1; TIMEOUT=300
EXPOSE=(); PROVIDERS=(); LABELS=(); ENVS=(); UPLOADS=()

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[openshell-provision] $*" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: openshell-provision.sh --usecase <profile> --name <sandbox> [options]

profiles: orchestrator | data | analysis | action | defense | train | inference | scratch

required:
  --usecase <p>          profile from the table above
  --name <n>             sandbox name

targeting:
  --workspace <w>        workspace (default: $OPENSHELL_WORKSPACE or "default")
  --gateway <g>          select this gateway before creating

overrides (profile supplies defaults):
  --image <ref>          --from value: base | ollama | ./dir | registry/img:tag
  --cpu <q>              500m | 1 | 2.5
  --memory <q>           512Mi | 4Gi | 64G
  --gpu <n>              GPU count (omit value on the profile to disable)
  --agent <cmd>          trailing agent command (default: claude, or none)
  --policy <file>        policy YAML, overrides the profile template

metering labels (all four recommended):
  --tenant <t> --pod <p> --mission <m> --agent-role <black|green|blue|yellow|red>

extras (repeatable):
  --provider <name>      attach credential provider (use this, not --env)
  --label k=v            additional label
  --env K=V              plain env var; NEVER for secrets
  --upload src:dst       upload at creation time
  --expose port[:name]   expose a service after Ready

behavior:
  --no-keep              delete the sandbox when the initial command exits
  --timeout <secs>       readiness timeout (default 300)
  --dry-run              print the resolved plan and command, create nothing
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --usecase)   USECASE="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --gateway)   GATEWAY="$2"; shift 2 ;;
    --image)     IMAGE="$2"; shift 2 ;;
    --cpu)       CPU="$2"; shift 2 ;;
    --memory)    MEMORY="$2"; shift 2 ;;
    --gpu)       GPU="$2"; shift 2 ;;
    --agent)     AGENT="$2"; shift 2 ;;
    --policy)    POLICY="$2"; shift 2 ;;
    --tenant)    TENANT="$2"; shift 2 ;;
    --pod)       POD="$2"; shift 2 ;;
    --mission)   MISSION="$2"; shift 2 ;;
    --agent-role)      AGENT_ROLE="$2"; shift 2 ;;
    --provider)  PROVIDERS+=("$2"); shift 2 ;;
    --label)     LABELS+=("$2"); shift 2 ;;
    --env)       ENVS+=("$2"); shift 2 ;;
    --upload)    UPLOADS+=("$2"); shift 2 ;;
    --expose)    EXPOSE+=("$2"); shift 2 ;;
    --no-keep)   KEEP=0; shift ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage ;;
    *)           die "unknown flag: $1 (try --help)" ;;
  esac
done

[[ -n "$USECASE" ]] || usage
[[ -n "$NAME" ]] || usage

# ---------- profile resolution -------------------------------------------
p_image="base"; p_cpu="2"; p_mem="4Gi"; p_gpu=""; p_policy=""; p_agent="claude"; p_agent_role=""

case "$USECASE" in
  orchestrator) p_cpu=2; p_mem=4Gi;  p_policy=orchestrator.yaml;  p_agent_role=black ;;
  data)         p_cpu=4; p_mem=8Gi;  p_policy=data.yaml;     p_agent_role=green ;;
  analysis)     p_cpu=4; p_mem=16Gi; p_policy=analysis.yaml; p_agent_role=blue ;;
  action)       p_cpu=2; p_mem=4Gi;  p_policy=action.yaml;   p_agent_role=red ;;
  defense)      p_cpu=2; p_mem=4Gi;  p_policy=defense.yaml;  p_agent_role=yellow ;;
  train)        p_cpu=8; p_mem=64Gi; p_gpu=1; p_policy=train.yaml; p_agent="" ;;
  inference)    p_cpu=4; p_mem=16Gi; p_gpu=1; p_policy=inference.yaml; p_image=ollama; p_agent="" ;;
  scratch)      p_cpu=2; p_mem=4Gi;  p_policy=scratch.yaml;       p_agent="" ;;
  *)            die "unknown usecase: $USECASE (see --help)" ;;
esac

IMAGE="${IMAGE:-$p_image}"
CPU="${CPU:-$p_cpu}"
MEMORY="${MEMORY:-$p_mem}"
GPU="${GPU:-$p_gpu}"
AGENT_ROLE="${AGENT_ROLE:-$p_agent_role}"
[[ -n "$AGENT" ]] || AGENT="$p_agent"
if [[ -z "$POLICY" ]]; then
  POLICY="$POLICY_DIR/$p_policy"
fi
[[ -f "$POLICY" ]] || die "policy template not found: $POLICY"

if grep -q 'REPLACE_' "$POLICY"; then
  log "WARNING: $POLICY still contains REPLACE_ placeholders."
  log "         Fill in the real hosts/paths before this sandbox can reach anything."
fi

# ---------- command assembly ---------------------------------------------
CMD=(openshell sandbox create --name "$NAME" --from "$IMAGE"
     --cpu "$CPU" --memory "$MEMORY" --policy "$POLICY")

[[ -n "$WORKSPACE" ]] && CMD+=(--workspace "$WORKSPACE")
[[ -n "$GPU" ]] && CMD+=(--gpu "$GPU")
[[ "$KEEP" -eq 0 ]] && CMD+=(--no-keep)

[[ -n "$TENANT"  ]] && CMD+=(--label "tenant=$TENANT")
[[ -n "$POD"     ]] && CMD+=(--label "pod=$POD")
[[ -n "$MISSION" ]] && CMD+=(--label "mission=$MISSION")
[[ -n "$AGENT_ROLE"    ]] && CMD+=(--label "agent=$AGENT_ROLE")
CMD+=(--label "usecase=$USECASE")

for l in "${LABELS[@]:-}";    do [[ -n "$l" ]] && CMD+=(--label "$l"); done
for p in "${PROVIDERS[@]:-}"; do [[ -n "$p" ]] && CMD+=(--provider "$p"); done
for u in "${UPLOADS[@]:-}";   do [[ -n "$u" ]] && CMD+=(--upload "$u"); done
for e in "${ENVS[@]:-}"; do
  [[ -n "$e" ]] || continue
  case "${e%%=*}" in
    *TOKEN*|*SECRET*|*PASSWORD*|*CREDENTIAL*|*API_KEY*|*ACCESS_KEY*)
      log "WARNING: --env ${e%%=*} looks like a credential. The agent can read it."
      log "         Attach it with --provider instead so the gateway injects it." ;;
  esac
  CMD+=(--env "$e")
done

# The CLI rejects `--output json` alongside a trailing [COMMAND]:
#   error: the argument '--output <OUTPUT>' cannot be used with '[COMMAND]...'
# Request structured output only when no agent command is appended.
if [[ -n "$AGENT" ]]; then
  CMD+=(-- $AGENT)
else
  CMD+=(--output json)
fi

cat >&2 <<PLAN

  plan
  ----
  usecase    $USECASE            agent       ${AGENT_ROLE:-n/a}
  sandbox    $NAME               workspace  ${WORKSPACE:-${OPENSHELL_WORKSPACE:-default}}
  image      $IMAGE              gateway    ${GATEWAY:-<active>}
  cpu        $CPU                memory     $MEMORY
  gpu        ${GPU:-none}        keep       $([[ $KEEP -eq 1 ]] && echo yes || echo no)
  policy     $POLICY
  agent      ${AGENT:-<none>}
  providers  ${PROVIDERS[*]:-none}
  expose     ${EXPOSE[*]:-none}

PLAN

printf '  %s\n\n' "${CMD[*]}" >&2

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: nothing created."
  exit 0
fi

# ---------- preflight -----------------------------------------------------
command -v openshell >/dev/null 2>&1 || die "openshell CLI not found in PATH"
[[ -n "$GATEWAY" ]] && openshell gateway select "$GATEWAY"
openshell whoami --output json >/dev/null || die "gateway auth failed; run: openshell whoami"

# ---------- create --------------------------------------------------------
log "creating sandbox $NAME ..."
"${CMD[@]}"

# ---------- wait for Ready ------------------------------------------------
WS_ARGS=()
[[ -n "$WORKSPACE" ]] && WS_ARGS=(--workspace "$WORKSPACE")

phase_of() {
  openshell sandbox get "$NAME" "${WS_ARGS[@]}" --output json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("Unknown"); raise SystemExit
while isinstance(d, dict) and "phase" not in d:
    nxt = d.get("sandbox") or d.get("status") or d.get("data")
    if not isinstance(nxt, dict):
        break
    d = nxt
print(d.get("phase", "Unknown") if isinstance(d, dict) else "Unknown")'
}

deadline=$(( $(date +%s) + TIMEOUT ))
phase=""
while [[ $(date +%s) -lt $deadline ]]; do
  phase="$(phase_of)"
  case "$phase" in
    Ready)  break ;;
    Error)  die "sandbox entered Error phase; run: openshell logs $NAME" ;;
    *)      log "phase=$phase ..."; sleep 5 ;;
  esac
done

[[ "$phase" == "Ready" ]] || die "timed out after ${TIMEOUT}s in phase=$phase (Provisioning with SupervisorNotConnected is normal; re-check with: openshell sandbox get $NAME)"

# ---------- expose services ----------------------------------------------
for spec in "${EXPOSE[@]:-}"; do
  [[ -n "$spec" ]] || continue
  port="${spec%%:*}"; svc="${spec#*:}"
  if [[ "$svc" == "$spec" ]]; then
    openshell service expose "$NAME" "$port"
  else
    openshell service expose "$NAME" "$port" "$svc"
  fi
done

# ---------- handoff -------------------------------------------------------
cat <<HANDOFF

sandbox ready
  name       $NAME
  workspace  ${WORKSPACE:-${OPENSHELL_WORKSPACE:-default}}
  phase      Ready
  exec with  openshell sandbox exec -n $NAME -- <command>
  logs       openshell logs $NAME --tail --source sandbox
  policy     openshell sandbox get $NAME --policy-only
  stop       openshell sandbox stop $NAME
HANDOFF

openshell service list "$NAME" 2>/dev/null || true
