#!/usr/bin/env bash
# openshell-provision.sh — usecase-driven OpenShell sandbox provisioning.
#
# Resolves a profile into a sandbox spec, renders its policy template, creates
# the sandbox, and blocks until the gateway reports phase=Ready.
#
#   ./openshell-provision.sh --usecase data --name green-ingest-01 \
#       --workspace tenant-acme --tenant acme --pod acme-prod --mission m-4471
#
#   ./openshell-provision.sh --usecase action --name red-act-01 \
#       --gateway actionboard-cloud --image registry.example/actionboard/base:1.4
#
# Always run with --dry-run first and show the plan before creating anything.
#
# --gateway names the OpenShell control plane. --pod is an ActionBoard tenancy
# label and nothing else; the two are never interchangeable. Connect a cloud
# gateway with /pod-connect before provisioning against it.
#
# Against a remote or cloud gateway this wrapper refuses two things the CLI
# would otherwise attempt on the LOCAL Docker daemon -- a `--image ./dir` and a
# Dockerfile build -- and refuses a policy that still carries REPLACE_
# placeholders. Both stay warnings on a local gateway.

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
  --gateway <g>          gateway to target and select before creating
                         (default: $OPENSHELL_GATEWAY, $ACTIONBOARD_GATEWAY_NAME,
                          else the currently active gateway)

overrides (profile supplies defaults):
  --image <ref>          --from value: base | ollama | ./dir | registry/img:tag
  --cpu <q>              500m | 1 | 2.5
  --memory <q>           512Mi | 4Gi | 64G
  --gpu <n>              GPU count (omit value on the profile to disable)
  --agent <cmd>          trailing agent command (default: claude, or none)
                         split on whitespace; not glob-expanded, and quotes
                         inside it are not honoured
  --policy <file>        policy YAML, overrides the profile template

metering labels (all four recommended):
  --tenant <t> --pod <p> --mission <m> --agent-role <black|green|blue|yellow|red>
  --pod is the ActionBoard tenancy label only. It is not the gateway.

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

# ---------- gateway resolution -------------------------------------------
# `gateway list` reads local registrations only -- no network, safe in --dry-run.
GATEWAY="${GATEWAY:-${OPENSHELL_GATEWAY:-${ACTIONBOARD_GATEWAY_NAME:-}}}"

gw_field() {
  command -v openshell >/dev/null 2>&1 || return 0
  openshell gateway list --output json 2>/dev/null \
    | GW="$GATEWAY" FIELD="$1" python3 -c 'import json,os,sys
gw, field = os.environ["GW"], os.environ["FIELD"]
try:
    rows = json.load(sys.stdin)
except Exception:
    raise SystemExit
if isinstance(rows, dict):
    rows = rows.get("gateways") or rows.get("items") or []
for r in rows:
    if (r.get("name") == gw) if gw else bool(r.get("active")):
        v = r.get(field)
        print("" if v is None else str(v).lower() if isinstance(v, bool) else v)
        break' 2>/dev/null
}

RESOLVED_GATEWAY="${GATEWAY:-$(gw_field name)}"
GW_TYPE="$(gw_field type)"
GW_AUTH="$(gw_field auth)"
GW_REMOTE="$(gw_field is_remote)"

REMOTE=0
[[ "$GW_REMOTE" == "true" ]] && REMOTE=1
case "$GW_TYPE" in remote|cloud) REMOTE=1 ;; esac
case "$GW_AUTH" in oidc|edge_bearer|edge) REMOTE=1 ;; esac

GW_LABEL="${RESOLVED_GATEWAY:-<none registered>}"
[[ "$REMOTE" -eq 1 ]] && GW_LABEL="$GW_LABEL (remote)"

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

if [[ "$REMOTE" -eq 1 ]]; then
  case "$IMAGE" in
    ./*|../*|/*|.|Dockerfile|*/Dockerfile|*.Dockerfile)
      die "refusing --image $IMAGE against remote gateway '$RESOLVED_GATEWAY': a local directory or Dockerfile is built by the CLI on THIS machine's Docker daemon, which the remote gateway cannot see. Push the image and pass a registry reference instead, e.g. --image registry.example/org/img:tag" ;;
  esac
fi

if grep -q 'REPLACE_' "$POLICY"; then
  if [[ "$REMOTE" -eq 1 ]]; then
    die "$POLICY still contains REPLACE_ placeholders; refusing to create against remote gateway '$RESOLVED_GATEWAY'. On a shared cloud gateway an unfilled policy is a sandbox that looks ready and can reach nothing. Fill in the real hosts/paths first."
  fi
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
  # Word-split --agent (intentional: it may be a multi-word command) but do NOT
  # glob it. read -ra splits on IFS with pathname expansion off. The command
  # runs INSIDE the sandbox, so a `*` expanded here would expand against the
  # caller's cwd -- the wrong filesystem, and against a cloud gateway a
  # different machine entirely. Quoting inside --agent is not honoured; pass a
  # single word and let the sandbox's own shell do the rest.
  read -ra AGENT_ARGV <<<"$AGENT"
  CMD+=(-- ${AGENT_ARGV[@]+"${AGENT_ARGV[@]}"})
else
  CMD+=(--output json)
fi

cat >&2 <<PLAN

  plan
  ----
  usecase    $USECASE            agent       ${AGENT_ROLE:-n/a}
  sandbox    $NAME               workspace  ${WORKSPACE:-${OPENSHELL_WORKSPACE:-default}}
  image      $IMAGE              gateway    $GW_LABEL
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
openshell whoami --output json >/dev/null 2>&1 || die "gateway '${RESOLVED_GATEWAY:-<none>}' has no validated identity. Authenticate it: openshell gateway login ${RESOLVED_GATEWAY:-<name>} -- or, for an ActionBoard cloud pod, run /pod-connect. (Do not re-run whoami; whoami is the call that just failed.)"

# ---------- create --------------------------------------------------------
log "creating sandbox $NAME ..."
"${CMD[@]}"

# ---------- wait for Ready ------------------------------------------------
# Expanded below as ${WS_ARGS[@]+"${WS_ARGS[@]}"}, not "${WS_ARGS[@]}": on bash
# 3.2 -- /bin/bash on macOS -- the plain form aborts with "unbound variable"
# under `set -u` when the array is empty, which is the no---workspace case. The
# ${a[@]:-} form survives set -u but passes a stray empty argument to the CLI;
# the +-form expands to nothing at all. The sandbox is already created by this
# point, so an abort here strands a billable sandbox the operator is told
# timed out.
WS_ARGS=()
[[ -n "$WORKSPACE" ]] && WS_ARGS=(--workspace "$WORKSPACE")

phase_of() {
  openshell sandbox get "$NAME" ${WS_ARGS[@]+"${WS_ARGS[@]}"} --output json 2>/dev/null \
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
