#!/usr/bin/env bash
# openshell-teardown.sh — stop or delete sandboxes, by name or label selector.
#
#   ./openshell-teardown.sh --name green-ingest-01 --stop
#   ./openshell-teardown.sh --selector mission=m-4471 --delete --workspace tenant-acme \
#       --gateway actionboard-cloud
#
# Delete purges injected credentials and releases resources. Prefer --stop for
# a mission that will resume: policies, providers, services, and persistent
# workspace data all survive a stop.
#
# --delete will NOT infer the gateway from the active selection. On a shared
# cloud gateway the active selection is whatever the last command left behind,
# and deleting into the wrong tenant is unrecoverable. Name it, every time.

set -euo pipefail

NAME=""; SELECTOR=""; WORKSPACE=""; GATEWAY=""; MODE=""; ARCHIVE=""; YES=0

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[openshell-teardown] $*" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: openshell-teardown.sh (--name <n> | --selector k=v[,k=v]) (--stop | --delete) [options]

  --name <n>         single sandbox
  --selector <sel>   label selector, e.g. mission=m-4471,agent=yellow
  --stop             release compute, retain state
  --delete           destroy, purge credentials  (irreversible)
  --workspace <w>    workspace to target
  --gateway <g>      gateway to target
                     [env OPENSHELL_GATEWAY, ACTIONBOARD_GATEWAY_NAME]
                     required for --delete; never inferred from the active
                     gateway, because deleting into the wrong cloud tenant
                     cannot be undone
  --archive <dir>    download the sandbox's output/ dir before acting
  --yes              skip the confirmation prompt
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="$2"; shift 2 ;;
    --selector)  SELECTOR="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --gateway)   GATEWAY="$2"; shift 2 ;;
    --archive)   ARCHIVE="$2"; shift 2 ;;
    --stop)      MODE="stop"; shift ;;
    --delete)    MODE="delete"; shift ;;
    --yes)       YES=1; shift ;;
    -h|--help)   usage ;;
    *)           die "unknown flag: $1" ;;
  esac
done

[[ -n "$MODE" ]] || usage
[[ -n "$NAME" || -n "$SELECTOR" ]] || usage
command -v openshell >/dev/null 2>&1 || die "openshell CLI not found in PATH"

GATEWAY="${GATEWAY:-${OPENSHELL_GATEWAY:-${ACTIONBOARD_GATEWAY_NAME:-}}}"

if [[ "$MODE" == "delete" && -z "$GATEWAY" ]]; then
  die "--delete requires an explicit --gateway <name> (or OPENSHELL_GATEWAY / ACTIONBOARD_GATEWAY_NAME). The active gateway is whatever the last command selected; on a multi-tenant cloud gateway that is how a mission gets deleted out of someone else's pod. List what is registered: openshell gateway list"
fi

# Targeting args: workspace and gateway, applied to every call below. Always
# expanded as ${WS_ARGS[@]+"${WS_ARGS[@]}"}, never "${WS_ARGS[@]}": on bash 3.2
# -- /bin/bash on macOS -- the plain form aborts with "unbound variable" under
# `set -u` when the array is empty, which is the case for --stop with neither
# --workspace nor --gateway. The ${a[@]:-} form survives set -u but passes a
# stray empty argument to the CLI; the +-form expands to nothing at all.
WS_ARGS=()
[[ -n "$WORKSPACE" ]] && WS_ARGS=(--workspace "$WORKSPACE")
[[ -n "$GATEWAY" ]] && WS_ARGS+=(-g "$GATEWAY")

log "gateway   ${GATEWAY:-<active selection>}"
log "workspace ${WORKSPACE:-${OPENSHELL_WORKSPACE:-default}}"
log "mode      $MODE"

# Declared before either branch so `${#TARGETS[@]}` below is bound even when
# the selector matches nothing.
TARGETS=()
if [[ -n "$NAME" ]]; then
  TARGETS=("$NAME")
else
  # A read loop, not `mapfile`: mapfile arrived in bash 4.0 and /bin/bash on
  # macOS is 3.2, where it exits 127 and takes the whole --selector path with
  # it.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    TARGETS+=("$line")
  done < <(
    openshell sandbox list ${WS_ARGS[@]+"${WS_ARGS[@]}"} --selector "$SELECTOR" -o json \
      | python3 -c 'import json,sys
d = json.load(sys.stdin)
items = d if isinstance(d, list) else (d.get("sandboxes") or d.get("items") or [])
for s in items:
    n = s.get("name") or s.get("id")
    if n: print(n)'
  )
fi

[[ ${#TARGETS[@]} -gt 0 ]] || die "no sandboxes matched"

log "targets: ${TARGETS[*]}"
if [[ "$MODE" == "delete" && "$YES" -eq 0 ]]; then
  read -r -p "delete ${#TARGETS[@]} sandbox(es)? this is irreversible [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted"
fi

for t in "${TARGETS[@]}"; do
  if [[ -n "$ARCHIVE" ]]; then
    mkdir -p "$ARCHIVE/$t"
    log "archiving $t -> $ARCHIVE/$t"
    # Signature is `sandbox download [OPTIONS] <NAME> <SANDBOX_PATH> [DEST]`
    # (openshell 0.0.110). The bare `output` is SANDBOX_PATH -- the path inside
    # the sandbox -- not a dropped `--`. Download refuses sources outside the
    # sandbox's canonical working directory, so this archives output/ only.
    openshell sandbox download "$t" output "$ARCHIVE/$t" ${WS_ARGS[@]+"${WS_ARGS[@]}"} || log "archive failed for $t (continuing)"
  fi
  log "$MODE $t"
  openshell sandbox "$MODE" "$t" ${WS_ARGS[@]+"${WS_ARGS[@]}"}
done

log "done. remaining:"
openshell sandbox list ${WS_ARGS[@]+"${WS_ARGS[@]}"} || true
