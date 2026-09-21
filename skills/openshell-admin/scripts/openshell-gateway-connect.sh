#!/usr/bin/env bash
# openshell-gateway-connect.sh — attach this machine to a remote ActionBoard
# cloud OpenShell gateway ("AI pod") and leave it authenticated and selected.
#
#   export ACTIONBOARD_POD_TOKEN="$(pbpaste)"
#   ./openshell-gateway-connect.sh \
#       --url https://gw.pod-4471.actionboard.example \
#       --oidc-issuer https://<pool>.auth.<region>.amazoncognito.com \
#       --oidc-audience openshell-gateway --oidc-scopes "openshell:all" \
#       --pod acme-prod --workspace tenant-acme --dry-run
#
# Always run with --dry-run first and show the plan before registering anything.
#
# ---------------------------------------------------------------------------
# THE ONE-TIME TOKEN IS A SECRET AND NEVER TOUCHES argv
# ---------------------------------------------------------------------------
# argv is recorded by the shell, by `ps`, and by hooks/audit-policy.sh. This
# wrapper therefore accepts the token ONLY from the environment variable
# ACTIONBOARD_POD_TOKEN or from stdin via --token-stdin, and refuses to start
# if a token-shaped value appears on the command line. Everything this script
# renders -- plan block, log lines, dry-run output, relayed CLI stderr -- is
# passed through redact() first, so the literal token cannot escape by way of
# a site someone forgot to hand-redact. No temp file is created, so there is
# no on-disk copy to shred: the token is handed to the CLI as a per-invocation
# environment assignment and never written anywhere.
#
# One leak path this script CANNOT close from inside: inline-prefixing its own
# invocation, e.g. `ACTIONBOARD_POD_TOKEN=xyz ./openshell-gateway-connect.sh`.
# That assignment is part of the CALLER's command line, not this script's, so
# nothing here can redact it. What happens to it depends on which version of
# hooks/audit-policy.sh is INSTALLED under ~/.claude/plugins:
#
#   0.6.1 and earlier -- this script's path contains "openshell", so the hook
#     matches the command, and its UNPARSED fallback writes the raw command
#     line, token included, into .openshell-audit.log.
#   0.7.0 -- the hook redacts the assignment instead. Measured against the
#     0.7.0 hook, an inline-prefixed invocation of this script produces no
#     audit entry at all: shlex strips the env prefix and this script's
#     basename is not "openshell".
#
# The installed copy is what runs, not the copy in this repository, and it
# stays whatever it was until the operator reinstalls the plugin. Assume the
# leaking version. Export the variable in a separate command, or pipe the
# token in with --token-stdin -- both are safe under either hook.
#
# ---------------------------------------------------------------------------
# TOKEN MECHANISM: OPENSHELL_OIDC_CLIENT_SECRET (native CLI env var)
# ---------------------------------------------------------------------------
# `openshell gateway add` and `openshell gateway login` have NO --token flag in
# v0.0.110, and none is invented here. The only headless credential input the
# CLI reads is the OAuth2 client-credentials secret, proven by two strings in
# the v0.0.110 binary:
#
#   "OPENSHELL_OIDC_CLIENT_SECRET environment variable is required for
#    client credentials flow"
#   "The OIDC provider does not advertise a device_authorization_endpoint.
#    Enable the device authorization grant on this client, or use client
#    credentials for headless automation."
#
# So the ActionBoard one-time token is presented to the CLI as the secret in
# the client-credentials token exchange against the configured OIDC issuer.
# The CLI performs the exchange and persists the resulting bundle itself, in
# ~/.config/openshell/gateways/<name>/oidc_token.json. This wrapper writes
# nothing under ~/.config/openshell by hand and depends on no file schema.
#
# Registration is kept non-interactive with OPENSHELL_NO_BROWSER=1, which the
# binary documents as "authentication skipped (OPENSHELL_NO_BROWSER is set).
# Authenticate later with: openshell gateway login".
#
# INFERRED (not provable from --help): the exact predicate the CLI uses to pick
# client-credentials over the device-code and browser flows. This wrapper sets
# OPENSHELL_NO_BROWSER=1 and OPENSHELL_OIDC_CLIENT_SECRET together on the login
# call to request the headless path. If the CLI instead skips authentication,
# the whoami verification below catches it and says so rather than reporting a
# false success.

set -euo pipefail

VERIFIED_CLI_VERSION="0.0.110"

URL=""; GW_NAME=""; OIDC_ISSUER=""; OIDC_CLIENT_ID=""; OIDC_AUDIENCE=""
OIDC_SCOPES=""; WORKSPACE=""; POD=""
TOKEN=""; TOKEN_STDIN=0; BROWSER=0; DRY_RUN=0; TIMEOUT=120

# redact() is the single choke point for the secret. Everything rendered to a
# human or a log goes through it; there are no hand-written redactions.
redact() {
  local s="$*"
  [[ -n "${TOKEN:-}" ]] && s="${s//"$TOKEN"/****}"
  [[ -n "${ACTIONBOARD_POD_TOKEN:-}" ]] && s="${s//"$ACTIONBOARD_POD_TOKEN"/****}"
  printf '%s' "$s"
}

die() { printf 'error: %s\n' "$(redact "$*")" >&2; exit 1; }
log() { printf '[pod-connect] %s\n' "$(redact "$*")" >&2; }
emit() { printf '%s\n' "$(redact "$*")" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: openshell-gateway-connect.sh --url <https://gateway> [options]

Registers, authenticates, and selects a remote ActionBoard cloud OpenShell
gateway. The one-time token is read from the environment or stdin, never argv.

required:
  --url <https://…>      cloud gateway endpoint   [env ACTIONBOARD_GATEWAY_URL]
                         http:// is refused: it skips mTLS and browser auth

identity (no defaults ship for the issuer — supply your pod's):
  --oidc-issuer <url>    OIDC issuer URL          [env ACTIONBOARD_OIDC_ISSUER]
  --oidc-client-id <id>  CLI client id            [env ACTIONBOARD_OIDC_CLIENT_ID]
  --oidc-audience <a>    API resource audience    [env ACTIONBOARD_OIDC_AUDIENCE]
  --oidc-scopes "a b"    space-separated scopes   [env ACTIONBOARD_OIDC_SCOPES]

targeting:
  --name <n>             local gateway name       [env ACTIONBOARD_GATEWAY_NAME]
                         default: actionboard-cloud
  --workspace <w>        workspace scope          [env OPENSHELL_WORKSPACE]
  --pod <id>             ActionBoard tenancy label [env ACTIONBOARD_POD_ID]
                         a pod is NOT a gateway and NOT a workspace

credential:
  (env ACTIONBOARD_POD_TOKEN)   one-time token — the default path
  --token-stdin          read the one-time token from stdin instead
  --browser              fall back to the interactive browser login flow

behavior:
  --timeout <secs>       identity verification timeout (default 120)
  --dry-run              print the resolved plan and commands, register nothing

Passing the token as an argv value is refused. argv is captured by the shell,
by ps, and by hooks/audit-policy.sh.
USAGE
  exit 2
}

# ---------- argv secret refusal (runs before parsing) ---------------------
TOKEN_FLAG_RE='^--?(token|token-value|tok|pod-token|one-time-token|onetime-token|otp|secret|client-secret|oidc-client-secret|password|passwd|pass)(=.*)?$'

looks_like_secret() {
  local v="$1"
  [[ "$v" == *://* ]] && return 1
  [[ "$v" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] && return 0
  [[ ${#v} -ge 32 && "$v" =~ ^[A-Za-z0-9._~+/=-]+$ && "$v" =~ [A-Z] && "$v" =~ [0-9] ]] && return 0
  return 1
}

secret_remedy() {
  cat >&2 <<'REMEDY'

  The one-time token must never appear on the command line. Instead:

    read -rs ACTIONBOARD_POD_TOKEN && export ACTIONBOARD_POD_TOKEN
    openshell-gateway-connect.sh --url https://… --dry-run

  read -rs echoes nothing and writes nothing to your shell history. Typing
  `export ACTIONBOARD_POD_TOKEN='<literal token>'` at an interactive prompt
  does put the token in ~/.zsh_history verbatim.

  or pipe it from a password manager:

    <pw-cli> show <item> | openshell-gateway-connect.sh --url https://… --token-stdin

REMEDY
}

for a in "$@"; do
  if [[ "$a" =~ $TOKEN_FLAG_RE ]]; then
    printf 'error: refusing %s — this wrapper has no token flag by design.\n' "${a%%=*}" >&2
    secret_remedy; exit 1
  fi
  if looks_like_secret "$a"; then
    printf 'error: refusing a token-shaped value on the command line.\n' >&2
    secret_remedy; exit 1
  fi
done

# ---------- flags ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)              URL="$2"; shift 2 ;;
    --name)             GW_NAME="$2"; shift 2 ;;
    --oidc-issuer)      OIDC_ISSUER="$2"; shift 2 ;;
    --oidc-client-id)   OIDC_CLIENT_ID="$2"; shift 2 ;;
    --oidc-audience)    OIDC_AUDIENCE="$2"; shift 2 ;;
    --oidc-scopes)      OIDC_SCOPES="$2"; shift 2 ;;
    --workspace)        WORKSPACE="$2"; shift 2 ;;
    --pod)              POD="$2"; shift 2 ;;
    --token-stdin)      TOKEN_STDIN=1; shift ;;
    --browser)          BROWSER=1; shift ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          usage ;;
    -*)                 die "unknown flag: $1 (try --help)" ;;
    *)                  printf 'error: unexpected positional argument.\n' >&2; secret_remedy; exit 1 ;;
  esac
done

URL="${URL:-${ACTIONBOARD_GATEWAY_URL:-}}"
GW_NAME="${GW_NAME:-${ACTIONBOARD_GATEWAY_NAME:-actionboard-cloud}}"
OIDC_ISSUER="${OIDC_ISSUER:-${ACTIONBOARD_OIDC_ISSUER:-}}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-${ACTIONBOARD_OIDC_CLIENT_ID:-}}"
OIDC_AUDIENCE="${OIDC_AUDIENCE:-${ACTIONBOARD_OIDC_AUDIENCE:-}}"
OIDC_SCOPES="${OIDC_SCOPES:-${ACTIONBOARD_OIDC_SCOPES:-}}"
WORKSPACE="${WORKSPACE:-${OPENSHELL_WORKSPACE:-}}"
POD="${POD:-${ACTIONBOARD_POD_ID:-}}"

[[ -n "$URL" ]] || usage

# ---------- 1. preflight --------------------------------------------------
command -v openshell >/dev/null 2>&1 || die "openshell CLI not found in PATH"

CLI_VERSION="$(openshell --version 2>/dev/null | awk '{print $NF}')"
if [[ "$CLI_VERSION" != "$VERIFIED_CLI_VERSION" ]]; then
  log "WARNING: openshell ${CLI_VERSION:-unknown} detected; this wrapper was built"
  log "         and verified against $VERIFIED_CLI_VERSION. Gateway flags and the"
  log "         headless OIDC path may have changed. Re-verify before trusting it."
fi

# ---------- 2. refuse a plaintext endpoint --------------------------------
case "$URL" in
  https://*) ;;
  http://*)  die "refusing $URL — an http:// endpoint registers a direct plaintext gateway that skips both mTLS and browser authentication. A cloud pod must be https://." ;;
  *)         die "--url must be an https:// URL (got: $URL)" ;;
esac

# ---------- 3. resolve the token ------------------------------------------
if [[ "$TOKEN_STDIN" -eq 1 ]]; then
  [[ -t 0 ]] && die "--token-stdin given but stdin is a terminal; pipe the token in"
  IFS= read -r TOKEN || true
elif [[ -n "${ACTIONBOARD_POD_TOKEN:-}" ]]; then
  TOKEN="$ACTIONBOARD_POD_TOKEN"
fi

if [[ -z "$TOKEN" && "$BROWSER" -eq 0 ]]; then
  printf 'error: no one-time token supplied and --browser not requested.\n' >&2
  secret_remedy
  printf '  Or use the interactive fallback: add --browser\n\n' >&2
  exit 1
fi

if [[ -n "$TOKEN" && "$BROWSER" -eq 1 ]]; then
  log "--browser given; ignoring the supplied one-time token and using the interactive flow."
  TOKEN=""
fi

if [[ -n "$TOKEN" && -z "$OIDC_ISSUER" ]]; then
  die "--oidc-issuer is required for the one-time-token path (no issuer default ships with this plugin — take it from your ActionBoard pod console)"
fi

AUTH_MODE="oidc client-credentials (headless, one-time token)"
[[ -n "$TOKEN" ]] || AUTH_MODE="browser login (interactive fallback)"

# ---------- 4. render the plan --------------------------------------------
ADD_CMD=(openshell gateway add "$URL" --name "$GW_NAME")
[[ -n "$OIDC_ISSUER"    ]] && ADD_CMD+=(--oidc-issuer "$OIDC_ISSUER")
[[ -n "$OIDC_CLIENT_ID" ]] && ADD_CMD+=(--oidc-client-id "$OIDC_CLIENT_ID")
[[ -n "$OIDC_AUDIENCE"  ]] && ADD_CMD+=(--oidc-audience "$OIDC_AUDIENCE")
[[ -n "$OIDC_SCOPES"    ]] && ADD_CMD+=(--oidc-scopes "$OIDC_SCOPES")
[[ -n "$WORKSPACE"      ]] && ADD_CMD+=(--workspace "$WORKSPACE")

LOGIN_CMD=(openshell gateway login "$GW_NAME")

if [[ -n "$TOKEN" ]]; then
  LOGIN_ENV_RENDERED='OPENSHELL_NO_BROWSER=1 OPENSHELL_OIDC_CLIENT_SECRET=****'
else
  LOGIN_ENV_RENDERED=''
fi

PLAN="$(cat <<PLAN

  plan
  ----
  gateway    $GW_NAME               pod        ${POD:-<unset>}
  endpoint   $URL
  auth       $AUTH_MODE
  issuer     ${OIDC_ISSUER:-<none — mTLS/edge gateway>}
  client-id  ${OIDC_CLIENT_ID:-<cli default: openshell-cli>}
  audience   ${OIDC_AUDIENCE:-<defaults to client id>}
  scopes     ${OIDC_SCOPES:-<issuer default>}
  workspace  ${WORKSPACE:-default}
  token      $([[ -n "$TOKEN" ]] && echo '**** (from '"$([[ "$TOKEN_STDIN" -eq 1 ]] && echo stdin || echo ACTIONBOARD_POD_TOKEN)"', never argv)' || echo '<none — browser flow>')

PLAN
)"

emit "$PLAN"
emit ""
emit "  OPENSHELL_NO_BROWSER=1 ${ADD_CMD[*]}"
emit "  ${LOGIN_ENV_RENDERED:+$LOGIN_ENV_RENDERED }${LOGIN_CMD[*]}"
emit "  openshell gateway select $GW_NAME"
emit ""

# ---------- 5. dry-run stops here, having created nothing -----------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "dry-run: nothing registered, nothing authenticated, nothing written."
  exit 0
fi

# ---------- 6. register, authenticate, select -----------------------------
gateway_field() {
  openshell gateway list --output json 2>/dev/null \
    | GW="$GW_NAME" FIELD="$1" python3 -c 'import json,os,sys
gw, field = os.environ["GW"], os.environ["FIELD"]
try:
    rows = json.load(sys.stdin)
except Exception:
    raise SystemExit
if isinstance(rows, dict):
    rows = rows.get("gateways") or rows.get("items") or []
for r in rows:
    if r.get("name") == gw:
        v = r.get(field)
        print("" if v is None else v)
        break'
}

EXISTING_ENDPOINT="$(gateway_field endpoint)"
if [[ -n "$EXISTING_ENDPOINT" ]]; then
  [[ "$EXISTING_ENDPOINT" == "$URL" ]] || die "gateway '$GW_NAME' is already registered to $EXISTING_ENDPOINT, not $URL. Remove it first: openshell gateway remove $GW_NAME"
  log "gateway '$GW_NAME' already registered to $URL; skipping add."
else
  log "registering gateway '$GW_NAME' ..."
  OPENSHELL_NO_BROWSER=1 "${ADD_CMD[@]}" || die "gateway add failed for $URL"
fi

log "authenticating ($AUTH_MODE) ..."
set +e
if [[ -n "$TOKEN" ]]; then
  LOGIN_OUT="$(OPENSHELL_NO_BROWSER=1 OPENSHELL_OIDC_CLIENT_SECRET="$TOKEN" "${LOGIN_CMD[@]}" 2>&1)"
else
  LOGIN_OUT="$("${LOGIN_CMD[@]}" 2>&1)"
fi
LOGIN_RC=$?
set -e
[[ -n "$LOGIN_OUT" ]] && emit "$LOGIN_OUT"

# ---------- 8. credential rejected by the IdP: its own error path ---------
consumed_token_die() {
  cat >&2 <<CONSUMED

error: the identity provider rejected this credential.

  Cognito answers invalid_client to all four of the causes below and this
  wrapper cannot tell them apart. Do NOT assume it is the token: burning fresh
  one-time tokens will not fix causes three or four.

    - the token was already used to connect (from this or another machine);
      a one-time token is valid for exactly one connect
    - the token passed its expiry window
    - the token was never valid for this issuer / client id / audience
    - the ActionBoard one-time token is not an OAuth2 client secret at all,
      making client-credentials the wrong mechanism for this pod. The header
      of this script marks that mapping INFERRED, not proven. If a second,
      freshly minted token fails identically, this is the likely cause —
      re-run with --browser to use the interactive flow instead.

  If you are treating this as a stale token: get a fresh one from the pod
  console, then:

    read -rs ACTIONBOARD_POD_TOKEN && export ACTIONBOARD_POD_TOKEN
    openshell gateway remove $GW_NAME
    <re-run this wrapper>

  gateway   $GW_NAME
  endpoint  $URL
  issuer    ${OIDC_ISSUER:-<none>}
  exit code $LOGIN_RC

CONSUMED
  exit 1
}

if [[ "$LOGIN_RC" -ne 0 ]]; then
  if printf '%s' "$LOGIN_OUT" | grep -qiE 'invalid_client|invalid_grant|unauthorized_client|already (used|consumed|redeemed)|expired|revoked|\b401\b|unauthenti|unauthorized'; then
    consumed_token_die
  fi
  die "gateway login failed (exit $LOGIN_RC) for '$GW_NAME'. This is NOT the one-time-token error path — the identity provider did not reject the credential. Check --oidc-issuer, --oidc-client-id, --oidc-audience, and network reachability of $URL."
fi

log "selecting gateway '$GW_NAME' ..."
openshell gateway select "$GW_NAME" || die "gateway select failed for '$GW_NAME'"

# ---------- 7. verify the identity the gateway actually sees --------------
GW_ARGS=(-g "$GW_NAME")
[[ -n "$WORKSPACE" ]] && GW_ARGS+=(--workspace "$WORKSPACE")

whoami_json() { openshell whoami "${GW_ARGS[@]}" --output json 2>/dev/null; }

deadline=$(( $(date +%s) + TIMEOUT ))
WHOAMI=""
while [[ $(date +%s) -lt $deadline ]]; do
  WHOAMI="$(whoami_json)"
  [[ -n "$WHOAMI" ]] && break
  log "identity not yet visible to the gateway; retrying ..."
  sleep 5
done

[[ -n "$WHOAMI" ]] || die "authenticated but 'openshell whoami' returned nothing within ${TIMEOUT}s. The gateway is registered but this session has no validated identity — if you used --browser, the login window may not have completed. Retry with: openshell gateway login $GW_NAME"

read -r SUBJECT IDP ROLES SCOPES < <(
  printf '%s' "$WHOAMI" | python3 -c 'import json,sys
def flat(d, *keys):
    for k in keys:
        v = d.get(k)
        if v:
            return ",".join(v) if isinstance(v, list) else str(v)
    return "-"
d = json.load(sys.stdin)
while isinstance(d, dict) and "subject" not in d:
    nxt = d.get("user") or d.get("current_user") or d.get("data")
    if not isinstance(nxt, dict):
        break
    d = nxt
print(flat(d, "subject", "sub"), flat(d, "identity_provider", "provider"),
      flat(d, "roles"), flat(d, "scopes"))'
)

WS_JSON="$(openshell workspace list "${GW_ARGS[@]}" --output json 2>/dev/null || true)"
WS_COUNT="$(printf '%s' "$WS_JSON" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
rows = d if isinstance(d, list) else (d.get("workspaces") or d.get("items") or [])
print(len(rows))' 2>/dev/null || echo 0)"

if [[ "$WS_COUNT" -eq 0 ]]; then
  cat >&2 <<NOMEMBER

error: connected and authenticated, but this subject has no workspace membership.

  subject   $SUBJECT
  provider  $IDP
  gateway   $GW_NAME ($URL)

  'openshell workspace list' returned no rows. Nothing can be provisioned until
  a Platform Admin grants this subject membership. Send them the subject above
  verbatim — it is the only handle they can act on.

NOMEMBER
  exit 1
fi

# ---------- 9. handoff ----------------------------------------------------
cat <<HANDOFF

gateway connected
  gateway    $GW_NAME
  endpoint   $URL
  auth       $(gateway_field auth)
  pod        ${POD:-<unset>}
  workspace  ${WORKSPACE:-default}    ($WS_COUNT visible)
  subject    $SUBJECT
  provider   $IDP
  roles      $ROLES
  scopes     $SCOPES
  provision  /sandbox-up   (or: openshell-provision.sh --gateway $GW_NAME --usecase <p> --name <n>${POD:+ --pod $POD})
  harness    /mission-harness
  disconnect openshell gateway logout $GW_NAME
HANDOFF
