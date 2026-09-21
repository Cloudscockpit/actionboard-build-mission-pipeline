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
#
# NOTHING IS APPENDED UNREDACTED. Every write path below -- the parsed CALL
# path, the UNPARSED fallback, and the no-python3 fallback -- runs the text
# through a redactor first. This hook matches on the substring `openshell`, and
# the cloud connect wrapper's own path contains `openshell`, so a caller who
# inline-prefixes the wrapper with ACTIONBOARD_POD_TOKEN=... hands this hook a
# live one-time token. The variable/flag NAME is kept (that is the audit value);
# only the value is replaced with ****.
#
# Command prefixes are resolved with the same WRAPPERS tuple the guard uses --
# env/sudo/nohup/time/exec/command, timeout/stdbuf/nice/ionice/watch/xargs and
# eval -- because a wrapper that hides a command from the guard must not also
# hide it from the paper trail. The two failing together is the one combination
# this file cannot allow.

# Bumped whenever the hook contract changes. These hooks execute from the
# INSTALLED plugin copy, never from the checkout, so this constant is how an
# operator proves which one is live:
#   grep -h HOOK_CONTRACT_VERSION ~/.claude/plugins/marketplaces/*/hooks/*.sh
# tests/smoke.sh asserts it equals "version" in .claude-plugin/plugin.json.
# shellcheck disable=SC2034  # a declared contract marker, read by grep and tests
HOOK_CONTRACT_VERSION="0.7.0"

set -uo pipefail

LOG="${OPENSHELL_AUDIT_LOG:-${CLAUDE_PROJECT_DIR:-.}/.openshell-audit.log}"
payload="$(cat)"

# Redactor for the no-python3 path. Token-wise, in awk (POSIX; present wherever
# bash is). Its classifier is the single-segment half of credential_like()
# below -- the PAIRS half adds nothing, since every pair contains KEY, TOKEN or
# SECRET, which are already single segments. If even awk is missing, the
# command text is elided rather than logged raw: the entry still records that
# an openshell command ran at that time, which is the point of the trail.
fallback_redact() {
  if command -v awk >/dev/null 2>&1; then
    awk '
      BEGIN {
        n = split("TOKEN SECRET PASSWORD PASSWD CREDENTIAL CREDENTIALS KEY APIKEY PAT AUTH PRIVATE CERT SESSION SIGNATURE BEARER", c, " ")
        for (i = 1; i <= n; i++) CRED[c[i]] = 1
      }
      function credlike(s,   u, m, seg, i) {
        sub(/^-+/, "", s)
        u = toupper(s)
        m = split(u, seg, /[_-]/)
        for (i = 1; i <= m; i++) if (seg[i] in CRED) return 1
        return 0
      }
      {
        line = ""; skip = 0
        n2 = split($0, t, /[ \t]+/)
        for (i = 1; i <= n2; i++) {
          tok = t[i]
          if (skip) { tok = "****"; skip = 0 }
          else if (index(tok, "=") > 1) {
            name = substr(tok, 1, index(tok, "=") - 1)
            if (credlike(name)) tok = name "=****"
          } else if (substr(tok, 1, 1) == "-" && credlike(tok)) {
            if (i < n2 && substr(t[i + 1], 1, 1) != "-") skip = 1
          }
          line = (line == "" ? tok : line " " tok)
        }
        print line
      }
    '
  else
    printf '%s\n' "<command elided: neither python3 nor awk available to redact it>"
  fi
}

# Same word boundary as GATE in the python block, spelled as a POSIX ERE so
# the two paths agree on what counts as an openshell command. Built in a
# variable because bash 3.2 needs the pattern unquoted; _SQ is a literal quote.
_SQ=$'\047'
GATE_RE="(^|[[:space:];&|(<\"${_SQ}/])openshell($|[[:space:];&|)>\"${_SQ}])"

command -v python3 >/dev/null 2>&1 || {
  # Cannot parse; record the command rather than silently dropping it -- but
  # redacted, one line, capped, and never the raw payload.
  # Flatten real AND JSON-escaped newlines/tabs first: on this path the text
  # being matched is the raw payload, where a command can start immediately
  # after a literal backslash-n and would otherwise miss the word boundary.
  flat="${payload//$'\n'/ }"; flat="${flat//$'\t'/ }"
  flat="${flat//\\n/ }"; flat="${flat//\\t/ }"
  if [[ "$flat" =~ $GATE_RE ]]; then
    redacted="$(printf '%s' "$flat" | fallback_redact)"
    redacted="${redacted%%$'\n'*}"
    if [ "${#redacted}" -gt 200 ]; then redacted="${redacted:0:200} ..."; fi
    { printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${CLAUDE_SESSION_ID:-nosession}" "UNPARSED" "$redacted" >> "$LOG"; } 2>/dev/null || true
  fi
  exit 0
}

entries="$(printf '%s' "$payload" | python3 -c '
import json, re, shlex, sys

# Verbs that mutate durable state. sandbox update is included because it can
# change a sandbox policy; workspace create/delete because the guard only asks
# about deletion, so without this the approved action leaves no trace.
#
# `gateway` verbs are ABSENT ON PURPOSE -- do not "fix" this by adding them.
# gateway add/login/remove/logout are the commands that carry the one-time pod
# token and the OIDC client secret, in argv or in an inline assignment. The
# guard already refuses a credential in argv and asks before remove/logout, so
# the destructive half is gated at the PreToolUse boundary; recording the other
# half here would put the credential-bearing command text into a file on disk
# for no audit value that the guard decision does not already carry.
AUDITED = {
    "policy",                                   # any policy subcommand
    "provider",                                 # any provider subcommand
    "sandbox create", "sandbox delete", "sandbox update", "sandbox exec",
    "workspace create", "workspace delete", "workspace update",
}

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


MARK = "****"
Q = chr(39)
# A value is a quoted string or a run of non-space.
VALUE = "(?:\"[^\"]*\"|" + Q + "[^" + Q + "]*" + Q + r"|[^\s]+)"
FLAGEQ = re.compile(r"(--?[A-Za-z0-9][\w\-]*)=(" + VALUE + ")")
ASSIGN = re.compile(r"(?<![\w.\-])([A-Za-z_][\w.\-]*)=(" + VALUE + ")")
FLAGSP = re.compile(r"(--?[A-Za-z0-9][\w\-]*)([ \t]+)(?!-)(" + VALUE + ")")


def _named(m):
    return m.group(1) + "=" + MARK if credential_like(m.group(1)) else m.group(0)


def _spaced(m):
    if credential_like(m.group(1)):
        return m.group(1) + m.group(2) + MARK
    return m.group(0)


def redact_text(s):
    """Redact arbitrary command text: VAR=v, --flag=v and --flag v."""
    s = FLAGEQ.sub(_named, s)
    s = ASSIGN.sub(_named, s)
    s = FLAGSP.sub(_spaced, s)
    return s


def redact_argv(argv):
    """Redact a parsed argv, token by token, then render it for the log."""
    rendered, i = [], 0
    while i < len(argv):
        tok = argv[i]
        if tok.startswith("-") and "=" in tok:
            name = tok.split("=", 1)[0]
            rendered.append(name + "=" + MARK if credential_like(name)
                            else shlex.quote(tok))
        elif tok.startswith("-") and credential_like(tok):
            rendered.append(shlex.quote(tok))
            if i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                rendered.append(MARK)
                i += 1
        elif not tok.startswith("-") and "=" in tok:
            # --env VAR=secret, and any other NAME=value argument.
            name = tok.split("=", 1)[0]
            rendered.append(name + "=" + MARK if credential_like(name)
                            else shlex.quote(tok))
        else:
            rendered.append(shlex.quote(tok))
        i += 1
    return " ".join(rendered)


try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

raw = normalize((payload.get("tool_input") or {}).get("command", "") or "")
# Word-boundaried: a grep for openshell-admin/, a heredoc that writes a doc
# mentioning the CLI, and .openshell-audit.log itself are not invocations, and
# every one of them used to land in the log as UNPARSED noise.
if not mentions_openshell(raw):
    sys.exit(0)


def invocations(text, depth=0):
    if depth > 3:
        return
    for part in SPLIT.split(normalize(text)):
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
            if head in EVAL and len(argv) > 1:
                yield from invocations(" ".join(argv[1:]), depth + 1)
                argv = []; continue
            if head in ("bash", "sh", "zsh") and "-c" in argv:
                i = argv.index("-c")
                if i + 1 < len(argv):
                    yield from invocations(argv[i + 1], depth + 1)
                argv = []; continue
            if head in WRAPPERS:
                argv = skip_wrapper(argv); continue
            break
        if argv and argv[0].rsplit("/", 1)[-1] == "openshell":
            yield ("CALL", argv)


# The UNPARSED path exists so an unparseable openshell command still leaves a
# trace, not so a heredoc can paste itself into the log a line at a time. One
# entry per tool call, 200 characters: enough to recognise the command, not
# enough to bury the state mutations that are the point of the file.
UNPARSED_MAX = 200
lines = []
unparsed_at = None
unparsed_extra = 0

for kind, item in invocations(raw):
    if kind == "UNPARSED":
        if unparsed_at is None:
            txt = redact_text(item).replace("\t", " ")
            if len(txt) > UNPARSED_MAX:
                txt = txt[:UNPARSED_MAX] + " ..."
            unparsed_at = len(lines)
            lines.append("UNPARSED\t" + txt)
        else:
            unparsed_extra += 1
        continue
    argv = item
    positional = [a for a in argv[1:] if not a.startswith("-")]
    group = positional[0].lower() if positional else ""
    verb = " ".join(positional[:2]).lower()
    if group in AUDITED or verb in AUDITED:
        lines.append((verb or group) + "\t" + redact_argv(argv).replace("\t", " "))

if unparsed_at is not None and unparsed_extra:
    lines[unparsed_at] += " [+%d more unparsed]" % unparsed_extra
for line in lines:
    print(line)
' 2>/dev/null)"

[[ -z "$entries" ]] && exit 0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Braces so an unwritable LOG path cannot even print a redirection error:
  # a PostToolUse hook writing to stderr is noise in the transcript.
  { printf '%s\t%s\t%s\n' "$ts" "${CLAUDE_SESSION_ID:-nosession}" "$line" >> "$LOG"; } 2>/dev/null || true
done <<< "$entries"

exit 0
