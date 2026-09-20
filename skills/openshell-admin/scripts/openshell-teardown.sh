#!/usr/bin/env bash
# openshell-teardown.sh — stop or delete sandboxes, by name or label selector.
#
#   ./openshell-teardown.sh --name green-ingest-01 --stop
#   ./openshell-teardown.sh --selector mission=m-4471 --delete --workspace tenant-acme
#
# Delete purges injected credentials and releases resources. Prefer --stop for
# a mission that will resume: policies, providers, services, and persistent
# workspace data all survive a stop.

set -euo pipefail

NAME=""; SELECTOR=""; WORKSPACE=""; MODE=""; ARCHIVE=""; YES=0

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
  --archive <dir>    download the sandbox workspace before acting
  --yes              skip the confirmation prompt
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      NAME="$2"; shift 2 ;;
    --selector)  SELECTOR="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
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

WS_ARGS=()
[[ -n "$WORKSPACE" ]] && WS_ARGS=(--workspace "$WORKSPACE")

if [[ -n "$NAME" ]]; then
  TARGETS=("$NAME")
else
  mapfile -t TARGETS < <(
    openshell sandbox list "${WS_ARGS[@]}" --selector "$SELECTOR" -o json \
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
    openshell sandbox download "$t" output "$ARCHIVE/$t" || log "archive failed for $t (continuing)"
  fi
  log "$MODE $t"
  openshell sandbox "$MODE" "$t" "${WS_ARGS[@]}"
done

log "done. remaining:"
openshell sandbox list "${WS_ARGS[@]}" || true
