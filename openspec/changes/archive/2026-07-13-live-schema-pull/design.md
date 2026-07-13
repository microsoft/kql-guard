## Context

kql-guard is a ~1000-line NativeAOT .NET 8 CLI. Its defining constraint is
**offline `lint`**: `KustoCode.Parse` → AST rules → `Violation` list → text/SARIF
→ exit. Two opt-in features already accept offline JSON files:
`--schema schemas.json` (`SchemaLoader.FromJson` → `GlobalState` for KQL101) and
`--table-sizes sizes.json` (`TableSizeEnricher : ICostEnricher` scales KQL003/008).
Both files are hand-authored today, which is why they go unused on real clusters.

This change adds the missing producer: an opt-in `pull` step that fills those
files from a live cluster. Everything hinges on one principle — **the live hop
is a separate, deliberate command, never part of `lint`.** `mattwar/Klint`
(written by the `Kusto.Language` author) validates the model: it fetches schema
via a `SymbolLoader` and caches it (`-generate`/`-cache`), then analyzes against
the cache. We adopt Klint's UX, not its implementation: Klint depends on
`Kusto.Data`/`Kusto.Toolkit`, which are reflection-heavy and not NativeAOT-safe.

## Goals / Non-Goals

**Goals:**
- Add `kql-guard pull --cluster <uri> --database <db>` that writes a
  `--schema`-format file (tables, columns, and stored functions).
- Fetch over the Kusto REST API with `HttpClient` + source-gen JSON only — no
  new dependency, NativeAOT preserved.
- Authenticate with a caller-supplied bearer token; no interactive auth in-binary.
- Bind pulled functions so KQL101 stops flagging user-defined functions.
- Optionally write a `--table-sizes` file (`--with-sizes`) for live cost scoring.

**Non-Goals:**
- No live connection during `lint`. `lint` stays 100% offline against files.
- No SDK (`Microsoft.Azure.Kusto.Data`) and no interactive/device-code/managed-
  identity acquisition inside the binary — the token arrives from outside.
- No multi-database merge, schema diffing, or drift alerts in v1 (one `pull` per
  `--database`; merging files is a later refinement).
- No resolution of server-only builtins/plugins absent from `Kusto.Language` —
  those genuinely need the server per query and are out of scope.

## Decisions

**1. `pull` is a subcommand, not a flag on `lint`.** `Program.Main` already
dispatches `fmt` at `args[0]` (Program.cs:28); `pull` slots in the same way. A
flag (`--cluster`) on `lint` would either connect on every CI run or require
cache-management logic in the hot path — both reject kql-guard's offline
premise. A subcommand keeps producer and consumer cleanly separated, exactly as
Klint separates `-generate` from analysis.

**2. REST-direct, no SDK.** `POST https://<cluster>/v1/rest/mgmt` with body
`{"db":"<db>","csl":".show database schema as json"}` and header
`Authorization: Bearer <token>`. The response is a Kusto response object whose
first table's first cell is a JSON string describing the schema. Parse both
layers with a source-generated `System.Text.Json` context (the project already
uses `KqlGuardSarifContext` for this reason). `Microsoft.Azure.Kusto.Data` is
**not** trimmer/AOT-safe (reflection-based serialization); adding it would defeat
the single-binary pillar. `HttpClient` + source-gen JSON are AOT-safe.

**3. Auth is an injected bearer token.** `--token <t>` or `KQL_GUARD_TOKEN`.
Rationale: CI already has a way to mint a Kusto token (federated credential,
managed identity, or `az account get-access-token --resource https://<cluster>`),
and keeping acquisition out of the binary avoids `Azure.Identity` (another
reflection/AOT liability) and keeps `pull` a thin, secretless-by-default HTTP
call. The token is read once, never written to logs or output, and sent only to
the user-specified cluster over HTTPS. Missing/empty token → usage error (exit 2).

**4. Output reuses the existing file formats.** `pull` writes the same
`{"Table":[{"name","type"}]}` map `SchemaLoader.FromJson` already reads, plus an
additive optional `functions` section (see Decision 5). `--with-sizes` writes
the existing `{"Table":factor}` map. No consumer-side format invention; the
offline pipeline is untouched. Recommended flow (documented, Klint's cache
model): run `pull` occasionally (or in a scheduled job), commit the file, and let
PRs `lint` offline against it.

**5. Functions extend the schema file additively.** `.show database schema as
json` includes stored functions (name, parameters, body). Extend the schema file
to an object `{"tables":{...}, "functions":[{"name","parameters","body"}]}` while
still accepting the current bare-map form for back-compat. `SchemaLoader` builds
`FunctionSymbol`s and adds them to the `DatabaseSymbol` so the binder resolves
calls. Ceiling: if binding full function bodies proves brittle across
`Kusto.Language` versions, fall back to registering the function *signature*
(name + result schema), which still clears the "unknown function" KQL101 —
document whichever holds during implementation. `ponytail:` this is the one place
the file format grows; keep the bare-map form working.

**6. Table-size factors are a normalized integer, computed at pull time.**
`TableSizeEnricher` multiplies weights by an integer factor, not raw bytes. So
`--with-sizes` converts each table's size (from `.show tables details` — one
call for all tables, `TotalOriginalSize` column) to `factor = max(1, round(size /
baseline))`, `baseline` = median table size or `--size-baseline <bytes>`. This is
a calibration knob, not a physical constant — real extents drift and compress
unevenly. `ponytail:` median baseline default; expose `--size-baseline` to tune.
Batch over per-table `.show table <t> details`: one round trip regardless of
table count, no throttling, no partial-failure loop; both need the same
privilege, so per-table buys nothing. `--with-sizes` requires Database Monitor
(a schema-only pull needs just Database Viewer) — another reason it stays opt-in.
Secondary and separable: schema pull ships without it if descoped.

**7. One `--database` per `pull` invocation.** The offline consumer is
single-database and flat: `SchemaLoader` builds one `DatabaseSymbol("db",
tables)` and neither file format carries a database dimension, so a multi-db
pull would have nowhere to land in v1. Batch is a caller-side shell loop
(`for db in A B; do pull --database $db -o $db.json; done`), matching Klint,
which also caches one file per database. Rejected: a merged multi-db file — that
needs cross-database binding in `SchemaLoader` (multiple `DatabaseSymbol`s + a
collision policy), and cross-db access is itself what KQL010 flags as costly; it
is a separate change if ever wanted. `ponytail:` producer follows consumer —
don't grow a dimension the consumer can't read. Natural, cheap future extension:
`--all-databases` (enumerate `.show databases`, write one file each).

## Risks / Trade-offs

- **Exact `.show database schema as json` shape** → capture one real response as
  a test fixture and parse against it (same empirical approach finops used for
  AST node kinds). Field names verified during implementation, not assumed here.
- **Function-body binding across `Kusto.Language` versions** → signature-only
  fallback (Decision 5) keeps KQL101 correct even if bodies don't bind.
- **Token handling (trust boundary)** → read from `--token`/`KQL_GUARD_TOKEN`
  only; never log; HTTPS only; fail closed on absence. Not simplified away.
- **AOT + HttpClient/JSON** → both are AOT-safe; the risk is only if a
  reflection-based JSON path sneaks in. Enforce source-gen contexts; a smoke
  `dotnet publish -r linux-x64` in CI catches regressions.
- **Sovereign/cloud-specific hosts** → the cluster URI is user-supplied, so no
  endpoint is hard-coded; `pull` composes `<uri>/v1/rest/mgmt`.

## Migration Plan

Purely additive. New `pull` subcommand; `lint`/`fmt`/existing flags/exit codes
unchanged. The `--schema` file gains an optional `functions` section that older
files simply lack. Rollback = revert the commit; committed schema files still
lint under the prior loader (bare-map form remains valid).

## Open Questions

None remaining. Both questions raised in review are resolved: single
`--database` per invocation (Decision 7) and `.show tables details` for table
sizes (Decision 6).
