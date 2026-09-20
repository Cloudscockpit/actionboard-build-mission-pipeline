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
