# Policy Recipes

## Policy shape

```yaml
version: 1

# STATIC — locked at sandbox creation. Changing these requires recreation.
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /etc]
  read_write: [/tmp]

landlock:
  compatibility: best_effort      # or hard_requirement

# process:                        # optional identity override
#   run_as_user: "1500"
#   run_as_group: "1500"

# DYNAMIC — hot-reloadable on a running sandbox.
network_policies:
  my_api:
    name: my-api
    endpoints:
      - host: api.example.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: full
    binaries:
      - path: /usr/bin/curl

network_middlewares: {}
```

A connection is allowed only when the destination **and** the calling binary
match inside the same policy block. An empty `binaries` list means any binary —
avoid it.

In proxy mode OpenShell adds baseline paths automatically: `/usr`, `/lib`,
`/etc`, `/var/log` read-only, `/tmp` read-write, plus the workdir when
`include_workdir: true`. GPU sandboxes also get GPU device nodes read-write and
move `/proc` to read-write for CUDA thread metadata.

`best_effort` skips a missing baseline path with a warning;
`hard_requirement` fails startup. User-listed paths are not pre-filtered — a
typo in `read_write` surfaces as a startup failure under `hard_requirement`.

## Endpoint spec grammar (`policy update --add-endpoint`)

```
host:port[:access[:protocol[:enforcement[:options]]]]
```

- `access`: `read-only` | `read-write` | `full` — expanded into method/path rules
- `protocol`: `rest` | `websocket` | `sql` (incremental); `graphql`, `mcp`,
  `json-rpc` require full YAML via `policy set`
- `enforcement`: `enforce` | `audit`
- omit `protocol` for plain L4 TCP passthrough (no payload inspection)

`api.github.com:443::rest` is **invalid** — an L7 endpoint with a protocol but
no `access` or `rules` is rejected at load.

A non-default port in the spec authorizes the tunnel; it does not change what
the client sends. The client must still put that port in its `Host:` header or
the gateway answers `request_authority_mismatch`. This bites on the ActionBoard
pod's `:9200` endpoint specifically — see the cloud blocks below.

Rule specs for `--add-allow` / `--add-deny`:

```
host:port:METHOD:path_glob
```

Quote it in shell when it contains `*`. `*` and `**` cross `/` boundaries; `?`
is one character; `[0-9]` and `[!0]` classes work. `--add-deny` requires the
endpoint to already have an allow base.

## Common blocks

**Package installs**

```yaml
pypi:
  name: pypi
  endpoints:
    - { host: pypi.org, port: 443 }
    - { host: files.pythonhosted.org, port: 443 }
  binaries:
    - { path: /usr/bin/pip }
    - { path: /usr/local/bin/uv }
```

npm equivalent: `registry.npmjs.org:443` bound to `/usr/bin/npm`.

**GitHub, read then narrow writes**

```bash
openshell policy update <name> \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --binary /usr/bin/gh --wait

openshell policy update <name> \
  --add-allow 'api.github.com:443:POST:/repos/*/issues' --wait

openshell policy update <name> \
  --add-deny 'api.github.com:443:POST:/admin/**' --wait
```

**Query-parameter constraint**

```yaml
download_api:
  name: download_api
  endpoints:
    - host: api.example.com
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow:
            method: GET
            path: "/api/v1/download"
            query:
              slug: "skill-*"
              version:
                any: ["1.*", "2.*"]
  binaries:
    - { path: /usr/bin/curl }
```

Query matchers are case-sensitive, run on decoded values, and every value of a
duplicated key must match.

**MCP server (full YAML only)**

```yaml
mcp_server:
  name: mcp_server
  endpoints:
    - host: mcp.example.com
      port: 443
      path: /mcp
      protocol: mcp
      enforcement: enforce
      mcp:
        max_body_bytes: 131072
      rules:
        - allow: { method: initialize }
        - allow: { method: notifications/initialized }
        - allow: { method: tools/call, tool: read_status }
        - allow:
            method: tools/call
            tool: { any: [submit_report, list_reports] }
      deny_rules:
        - { method: tools/call, tool: delete_resource }
  binaries:
    - { path: /usr/bin/python3 }
```

`mcp.allow_all_known_mcp_methods` defaults to `false`, so explicit method rules
are required. `strict_tool_names` defaults to `true` and is required for
wildcard `tool` matchers. Enforcement is directional — only sandbox-to-server
request bodies are inspected; responses and SSE are relayed unparsed. An MCP
endpoint cannot share a host and port with a differently inspected endpoint.

**GraphQL**

```yaml
github_graphql:
  name: github_graphql
  endpoints:
    - host: api.github.com
      port: 443
      path: "/graphql"
      protocol: graphql
      enforcement: enforce
      rules:
        - allow: { operation_type: query, fields: [viewer, repository] }
        - allow: { operation_type: mutation, operation_name: "Issue*", fields: [createIssue] }
      deny_rules:
        - { operation_type: mutation, fields: [deleteRepository] }
  binaries:
    - { path: /usr/bin/gh }
```

Allow rules require *every* selected root field to match; one matching field
blocks a deny rule. Batched requests are fail-closed. Hash-only persisted
queries are denied unless `persisted_queries: allow_registered` with a trusted
registry entry.

**WebSocket**

`protocol: websocket` validates the RFC 6455 upgrade, evaluates `GET` rules for
the handshake, and `WEBSOCKET_TEXT` rules for client text messages. Path globs
match the upgrade path, not payload content. A hot reload closes the relay with
code `1012` when the pinned generation goes stale.

## ActionBoard cloud pod blocks

For a sandbox that must reach the ActionBoard pod control plane. "Pod" here is
the ActionBoard tenancy/billing pod (`--pod`, `--label pod=`, `pod-free-001`),
not the OpenShell gateway — these blocks govern sandbox **egress** and are
unrelated to which gateway the CLI logged in to.

Hosts are placeholders on purpose; a shipped recipe must not point at
production. The verified real values live in `policies/actionboard-okf.yaml`
and are named in the comments of `policies/actionboard-cloud.yaml`, which is
the assembled version of all three blocks below.

**ActionBoard pod API**

```yaml
actionboard_pod_api:
  name: actionboard-pod-api
  endpoints:
    - host: REPLACE_POD_API_HOST          # e.g. genai.actionboard.com.bd
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: GET,  path: "/**" }
        - allow: { method: POST, path: "/pods/REPLACE_POD_ID/chat" }
      deny_rules:
        - { method: DELETE, path: "/**" }
        - { method: POST,   path: "/admin/**" }
    - host: REPLACE_POD_API_HOST          # same host, search/index port
      port: 9200
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: GET,  path: "/**" }
        - allow: { method: HEAD, path: "/**" }
      deny_rules:
        - { method: DELETE, path: "/**" }
        - { method: POST,   path: "/admin/**" }
  binaries:
    - { path: /sandbox/.uv/python/cpython-3.14.3-linux-aarch64-gnu/bin/python3.14 }
    - { path: /sandbox/.venv/bin/python3 }
    - { path: /usr/bin/curl }
```

The single POST is scoped to one pod id. A second pod is a second rule, added
deliberately — do not reach for `/pods/*/chat`.

**Billing / metering, read-only**

```yaml
actionboard_billing:
  name: actionboard-billing
  endpoints:
    - host: REPLACE_BILLING_HOST          # e.g. api-billing.actionboard.ai
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: GET,  path: "/**" }
        - allow: { method: HEAD, path: "/**" }
      deny_rules:
        - { method: DELETE, path: "/**" }
        - { method: POST,   path: "/admin/**" }
  binaries:
    - { path: /usr/bin/curl }
```

`access: read-only` is the shorthand for the same intent and is what
`actionboard-okf.yaml` uses. Spell the rules out when you also want
`deny_rules`, which need an allow base to attach to. Metering is read: a
mission that thinks it needs to POST here is a mission that has confused
reporting usage with recording it.

**Cognito token endpoint**

```yaml
actionboard_auth:
  name: actionboard-auth
  endpoints:
    - host: REPLACE_AUTH_HOST             # the tenant's Cognito user-pool domain
      port: 443
      protocol: rest
      enforcement: enforce
      rules:
        - allow: { method: POST, path: "/oauth2/token" }
        - allow: { method: GET,  path: "/oauth2/**" }
      deny_rules:
        - { method: DELETE, path: "/**" }
        - { method: POST,   path: "/admin/**" }
  binaries:
    - { path: /usr/bin/curl }
```

`absaas-dev.auth.ap-southeast-1.amazoncognito.com` is the pool currently
hardcoded in `policies/actionboard-okf.yaml`. It is the **dev** pool. Never
carry it into a cloud or production run as a default — ask which pool belongs
to the tenant. The pool a sandbox exchanges tokens against is also not
necessarily the OIDC issuer the CLI used to log in to the gateway; confirm
rather than assume they are one.

Incremental equivalent, when you are widening a live sandbox against an
observed denial rather than writing the file up front:

```bash
openshell policy update <name> \
  --add-endpoint <pod-api-host>:443:read-only:rest:enforce \
  --binary /usr/bin/curl --wait

openshell policy update <name> \
  --add-allow '<pod-api-host>:443:POST:/pods/<pod-id>/chat' --wait

openshell policy update <name> \
  --add-deny '<pod-api-host>:443:POST:/admin/**' --wait
```

### Two rules this path keeps tripping over

**`credential_endpoint_mismatch` is never fixed by widening this policy.** The
error means policy already admitted the request and the *provider profile* did
not authorize that credential for that host, port, and path. A sandbox policy
allow does not expand a credential binding. Export the profile
(`openshell provider profile export <id> -o yaml`), fix the endpoint list
there, and leave the sandbox policy alone. Widening it turns a precise,
correct denial into a sandbox that can reach the pod API with no credential —
which then fails later, further from the cause.

**`request_authority_mismatch` means the client omitted the port.** The
authorized tunnel endpoint is `host:9200`; an HTTP client that sends
`Host: <pod-api-host>` without the port presents a different authority and the
gateway refuses it. Send the port explicitly:

```bash
curl -H 'Host: <pod-api-host>:9200' http://<pod-api-host>:9200/_cluster/health
```

This is a client fix, not a policy fix. Adding endpoints until the error stops
will not stop it, because every added endpoint has the same mismatch.

## Credentials

Attach with `--provider`, not `--env`. Placeholders resolve as
`openshell:resolve:env:KEY`, and only when host, port, and path match an
endpoint in the provider profile — a sandbox policy allow does not expand that
binding. A mismatch returns HTTP 403 `credential_endpoint_mismatch`.

- `request_body_credential_rewrite: true` — inspected REST endpoints only,
  buffers up to 256 KiB, rejects unresolved placeholders.
- `websocket_credential_rewrite: true` — WebSocket, or REST compatibility
  endpoints performing an upgrade.
- `allow_uninspected_credentials: true` — last resort for credentialed L4-only
  or `tls: skip` endpoints. Without it the gateway rejects them. Record why.

## Global policy

```bash
openshell policy set --global --policy ./global-policy.yaml
openshell policy delete --global
openshell settings get <name>          # shows policy source and revision
```

While a global policy exists, **all** sandbox-level policy updates are
rejected. Use it only for a platform-wide baseline, and tell the user it blocks
per-sandbox iteration before you apply it.
