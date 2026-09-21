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
#
# Command prefixes are resolved, not just recognised: env/sudo/nohup/time/exec/
# command, and timeout/stdbuf/nice/ionice/watch/xargs/eval, are stepped over
# together with the arguments that belong to THEM, so `timeout 30 openshell
# sandbox delete --all-workspaces` is the same decision as the bare command.
# `$(which openshell)` is rewritten; runtime indirection such as `$OSH` is not
# reachable by a shlex-based parser and is stated as a limit, not covered.

# Bumped whenever the hook contract changes. These hooks execute from the
# INSTALLED plugin copy, never from the checkout, so this constant is how an
# operator proves which one is live:
#   grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/marketplaces/*/hooks/*.sh
# tests/smoke.sh asserts it equals "version" in .claude-plugin/plugin.json.
# shellcheck disable=SC2034  # a declared contract marker, read by grep and tests
HOOK_CONTRACT_VERSION="0.7.0"

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

# --- shared parser + credential classifier -------------------------------
# Byte-identical in hooks/guard-openshell.sh and hooks/audit-policy.sh, and
# tests/smoke.sh asserts both halves of that. The guard decides what to refuse
# and the audit hook decides what to record: if these drift, a command one of
# them sees through is a command the other is blind to, and a credential one
# refuses is a credential the other writes to disk in the clear.
CRED = {"TOKEN","SECRET","PASSWORD","PASSWD","CREDENTIAL","CREDENTIALS","KEY",
        "APIKEY","PAT","AUTH","PRIVATE","CERT","SESSION","SIGNATURE","BEARER"}
PAIRS = {("API","KEY"),("ACCESS","KEY"),("SECRET","KEY"),("PRIVATE","KEY"),
         ("REFRESH","TOKEN"),("ACCESS","TOKEN"),("CLIENT","SECRET")}
ALWAYS = {"ACTIONBOARD_POD_TOKEN", "OPENSHELL_OIDC_CLIENT_SECRET"}

SPLIT = re.compile(r"&&|\|\||;|\||\n")

# Command prefixes to step over before the real command. `timeout 30 openshell`
# is not an evasion -- it is what gets written to avoid a hang -- but every
# prefix here makes argv[0] something other than openshell, and a hook that
# stops at argv[0] loses both the decision and the audit entry at once.
WRAPPERS = ("env", "command", "nohup", "sudo", "time", "exec", "eval",
            "timeout", "stdbuf", "nice", "ionice", "watch", "xargs")
# Wrappers whose own first non-flag argument is a duration or an interval
# rather than the command: `timeout 30 openshell`, `watch 5 openshell`.
WRAPPER_ARG = ("timeout", "watch")
DURATION = re.compile(r"^[0-9]+([.][0-9]+)?[smhd]?$")
# eval concatenates its arguments with spaces and re-parses them, so it is
# recursed into exactly like `bash -c`.
EVAL = ("eval",)

# $(which openshell) resolves to the binary, but shlex sees two junk tokens.
# Only these fixed lookup idioms are rewritten. $OSH, ${BIN}/openshell and
# anything else built at runtime stay out of reach of a shlex parser by
# construction -- the hooks are a blast-radius seatbelt, not a sandbox.
SUBST = re.compile(r"[$]\((?:which|command\s+-v|type\s+-p)\s+openshell\)"
                   r"|`(?:which|command\s+-v|type\s+-p)\s+openshell`")

# Word-boundaried, so the hooks react to the openshell COMMAND and not to
# openshell-admin/, openshell-gateway-connect.sh, .openshell-audit.log or the
# word inside a heredoc of prose. A literal quote cannot appear in this block
# (it is single-quoted by the shell), hence chr(39).
_Q = chr(39)
GATE = re.compile("(^|[\\s;&|(<\"" + _Q + "/])openshell($|[\\s;&|)>\"" + _Q + "])")


def normalize(text):
    """Rewrite the fixed `$(which openshell)` idioms to a bare token."""
    return SUBST.sub("openshell", text)


def mentions_openshell(text):
    """True when the text contains the openshell command, not just the word."""
    return GATE.search(text) is not None


def skip_wrapper(argv):
    """Consume one command wrapper plus the arguments that belong to IT."""
    head = argv[0]
    argv = argv[1:]
    while argv and argv[0].startswith("-"):
        argv = argv[1:]                    # -oL, --signal=KILL, -n 5, -I
    if (argv and argv[0].rsplit("/", 1)[-1] != "openshell"
            and (head in WRAPPER_ARG or DURATION.match(argv[0])
                 or argv[0] == "{}")):
        argv = argv[1:]                    # timeout 30 / watch 5 / xargs -I {}
    return argv


def credential_like(name):
    """Segment match: TOKENIZERS_PARALLELISM and PASSWORDLESS_LOGIN do not trip."""
    name = name.strip("-")
    if name.upper() in ALWAYS:
        return True
    segs = re.split(r"[_\-]", name.upper())
    return (any(s in CRED for s in segs)
            or any(a in segs and b in segs for a, b in PAIRS))


# A credential-shaped NAME whose last segment points at a reference rather than
# the secret itself -- --token-file, --secret-name, --auth-mode, --cert-path.
# Without this, ordinary flags get denied and the guard gets switched off.
INDIRECT = {"FILE","PATH","DIR","MODE","NAME","ID","TYPE","URL","ENV","STDIN",
            "REF","ARN","SOURCE","PROVIDER"}
EXT = {"crt","pem","key","cer","p12","pfx","json","yaml","yml","conf","cfg"}

# token_shaped() is deliberately NARROWER than looks_like_secret() in
# skills/openshell-admin/scripts/openshell-gateway-connect.sh. They are not
# interchangeable, and the differences are the point, not drift:
#   * the wrapper allows "/" in its opaque charset. Here every non-flag argv
#     token is tested, including --archive paths and image refs, so "/" in
#     OPAQUE would turn a long path into a denied credential. A secret that
#     really does contain "/" is caught by B64 instead, which admits "/" but
#     excludes the "." "_" "-" that every path and image ref carries.
#   * the wrapper treats any three dot-separated segments as a JWT. Here that
#     also describes api.github.com, a legitimate --add-endpoint value, so JWT
#     below demands segment lengths no hostname has (a real signature segment
#     is 27+ characters; the longest plausible TLD label is far shorter).
# The asymmetry is deliberate: a deny refuses to run a real command, so the
# guard pays for a false positive in a way the wrapper -- which only vets its
# own argv, where a bare positional is already refused -- never does.
OPAQUE = re.compile(r"^[A-Za-z0-9._~+=-]+$")
B64 = re.compile(r"^[A-Za-z0-9+/=]+$")
JWT = re.compile(r"^[A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{16,}[.][A-Za-z0-9_-]{20,}$")
# NAME=value, where NAME is a real identifier. Without the identifier test,
# base64 padding ("...AbCd0123==") reads as an assignment and only the "=="
# tail gets shape-tested, which let a padded secret through.
ASSIGN_TOK = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*=")


def reference_like(value):
    """A path, a URL or a filename is a pointer to a secret, not the secret."""
    if not value:
        return True
    if "://" in value or "/" in value or value.startswith("~"):
        return True
    return "." in value and value.rsplit(".", 1)[-1].lower() in EXT


def token_shaped(value):
    """A value that is a secret by shape, whatever flag it arrived under."""
    if len(value) < 32 or "://" in value:
        return False
    if JWT.match(value):
        return True                        # a JWT need not be mixed case
    if not (re.search(r"[A-Z]", value) and re.search(r"[0-9]", value)):
        return False
    return bool(OPAQUE.match(value)
                or (B64.match(value) and not value.startswith("/")))


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

raw = normalize((payload.get("tool_input") or {}).get("command", "") or "")
# Word-boundaried on the parsed command. The malformed-payload check above
# stays a plain substring on purpose: that path cannot parse anything, so it
# errs wide and asks.
if not mentions_openshell(raw):
    sys.exit(0)


def invocations(text, depth=0):
    """Yield (env prefix, argv tail) for every openshell invocation."""
    if depth > 3:
        return
    for part in SPLIT.split(normalize(text)):
        part = part.strip()
        if not part:
            continue
        argv = shlex.split(part)          # ValueError on unbalanced quotes
        env = {}
        while argv:
            head = argv[0]
            if not head.startswith("-") and "=" in head:
                k, v = head.split("=", 1)  # VAR=value prefix
                env[k] = v
                argv = argv[1:]
                continue
            if head in EVAL and len(argv) > 1:
                yield from invocations(" ".join(argv[1:]), depth + 1)
                argv = []
                continue
            if head in ("bash", "sh", "zsh") and "-c" in argv:
                i = argv.index("-c")
                if i + 1 < len(argv):
                    yield from invocations(argv[i + 1], depth + 1)
                argv = []
                continue
            if head in WRAPPERS:
                argv = skip_wrapper(argv)
                continue
            break
        if argv and argv[0].rsplit("/", 1)[-1] == "openshell":
            yield env, argv[1:]


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


try:
    calls = list(invocations(raw))
except ValueError:
    out("parse_error")

for env, argv in calls:
    positional = [a for a in argv if not a.startswith("-")]
    verb = " ".join(positional[:2]).lower()
    pairs = list(flags(argv))
    names = {n for n, _ in pairs}

    # 1. TLS verification disabled. Checked before the verb rules so it denies
    #    even when the verb alone would only have asked.
    if "--gateway-insecure" in names:
        out("deny", "--gateway-insecure disables TLS verification of the gateway "
                    "certificate. Against a shared multi-tenant cloud gateway that "
                    "turns a trust failure into a silent MITM window over every "
                    "command and over the credential exchange itself. It is a "
                    "debugging flag for a self-signed LOCAL gateway. Fix the trust "
                    "chain instead: install the gateway CA at "
                    "~/.config/openshell/gateways/<name>/mtls/ca.crt, or re-register "
                    "the gateway with the right https:// endpoint.")

    # 2. A credential on the command line. argv is captured by shell history,
    #    by `ps`, and by the PostToolUse audit hook in this plugin. The connect
    #    wrapper refuses this on its own input; this catches the direct CLI call.
    for name, value in pairs:
        segs = re.split(r"[_\-]", name.strip("-").upper())
        if (credential_like(name) and segs[-1] not in INDIRECT
                and not reference_like(value)):
            out("deny", "%s passes a credential as an argv value. argv is recorded "
                        "by the shell history, by `ps`, and by the "
                        "audit hook. Supply it in the environment instead "
                        "(ACTIONBOARD_POD_TOKEN / OPENSHELL_OIDC_CLIENT_SECRET, "
                        "exported in its own command) or pipe it in with "
                        "/pod-connect --token-stdin." % name)
    for tok in argv:
        if tok.startswith("-"):
            continue
        value = tok.split("=", 1)[1] if ASSIGN_TOK.match(tok) else tok
        if token_shaped(value):
            out("deny", "A token-shaped value appears in argv. argv is recorded by "
                        "the shell history, by `ps`, and by the audit "
                        "hook, so a secret placed there is already leaked. Supply it "
                        "in the environment (ACTIONBOARD_POD_TOKEN / "
                        "OPENSHELL_OIDC_CLIENT_SECRET, exported in its own command) "
                        "or pipe it in with /pod-connect --token-stdin.")

    # 3. Cross-workspace destruction: can empty a tenant never part of this mission.
    if verb == "sandbox delete" and ({"--all-workspaces", "--all"} & names):
        out("deny", "Refusing a cross-workspace sandbox delete. Target one "
                    "workspace with --workspace, or delete by explicit name.")

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

    # 5. Endpoint override: retargets the command at a raw URL and bypasses the
    #    stored per-gateway metadata. OPENSHELL_GATEWAY_ENDPOINT is the same
    #    mechanism through the environment, so it is treated identically.
    if "--gateway-endpoint" in names or "OPENSHELL_GATEWAY_ENDPOINT" in env:
        out("ask", "This overrides the gateway endpoint directly and bypasses the "
                   "stored registration (auth mode, CA, workspace) of the selected "
                   "gateway, so the command can act on a different gateway than "
                   "`openshell gateway list` shows as selected. Confirm the endpoint "
                   "is the one you mean, or target a registered gateway by name with "
                   "-g/--gateway.")

    # 6. Global policy: while one exists, per-sandbox policy updates are rejected.
    if verb == "policy set" and "--global" in names:
        out("ask", "This sets a platform-wide policy. While it is active, all "
                   "sandbox-level policy updates are rejected until it is deleted. "
                   "Confirm this is a deliberate baseline change.")

    # 7. Workspace deletion.
    if verb == "workspace delete":
        out("ask", "Deleting a workspace removes its membership records and "
                   "inference routes. Confirm the workspace is empty and that "
                   "this is intended.")

    # 8. Destroying stored auth material. On a cloud pod the credential was a
    #    ONE-TIME token: it cannot be replayed, so recovery needs a human to
    #    mint a fresh one from the pod console. Both are deliberate, end-of-
    #    mission actions, so an ask here is one confirmation, not a nag.
    if verb in ("gateway remove", "gateway logout"):
        out("ask", "This destroys the stored credential for that gateway%s. If it "
                   "was connected with a one-time ActionBoard pod token, that token "
                   "is spent and cannot be reused -- reconnecting needs a NEW "
                   "one-time token from the pod console. Confirm the mission is "
                   "finished with this gateway."
                   % (" and its registration (endpoint, issuer, workspace)"
                      if verb == "gateway remove" else ""))

    # 9. access: full on an endpoint.
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
