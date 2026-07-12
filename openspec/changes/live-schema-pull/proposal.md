## Why

kql-guard's biggest limitation, raised in post-demo review, is that it is
schema-blind by default: `--schema` and `--table-sizes` both require a
hand-authored JSON file. Nobody maintains those by hand for a real cluster, so
KQL101 (unknown column/table/function) and live-accurate cost scoring go unused.
Queries that call **stored functions** can't be analyzed offline at all, because
the function bodies live in the database.

The fix is **not** to make the linter connect on every CI run — that would
reintroduce the auth, network, and flakiness kql-guard exists to remove, and
break the "offline" promise. Instead, add a separate, opt-in **`pull`** step
that fetches a cluster's schema once and writes it into the exact `--schema` /
`--table-sizes` files the offline linter already consumes. This mirrors the
proven model in `mattwar/Klint` (by the `Kusto.Language` author): a `-generate`
step populates a schema cache, and analysis then runs against the cache.

## What Changes

- Add a **`pull` subcommand** (dispatched like the existing `fmt`):
  `kql-guard pull --cluster <uri> --database <db> [-o schemas.json] [--with-sizes sizes.json]`.
  It connects to the cluster, runs `.show database schema as json`, and writes a
  `--schema`-format file. The `lint` path is untouched and stays fully offline.
- **Talk to the Kusto REST endpoint directly** (`POST /v1/rest/mgmt`) with
  `HttpClient` + source-generated `System.Text.Json`. **Do not** add
  `Microsoft.Azure.Kusto.Data` — it is reflection-heavy and not NativeAOT-safe,
  which would break the single-binary pillar.
- **Auth is a bearer token**, supplied via `--token` or the `KQL_GUARD_TOKEN`
  env var (obtained out-of-band, e.g. `az account get-access-token` or a CI
  federated/managed-identity token). kql-guard performs no interactive sign-in
  and links no Azure identity SDK.
- **Capture stored functions** in the pulled schema and bind them during
  analysis, so calls to user-defined functions no longer report KQL101. This is
  the "functions can't be linted offline" gap.
- **Optionally emit table-size factors** (`--with-sizes`) in the existing
  `--table-sizes` format, so live cost enrichment needs no new pipeline — it
  reuses `TableSizeEnricher`.

## Capabilities

### New Capabilities
- `live-schema-pull`: An opt-in subcommand that fetches a live cluster's schema
  (tables, columns, stored functions) and optional table sizes over the Kusto
  REST API using a caller-supplied bearer token, and writes them into the files
  the offline linter consumes. No SDK dependency; the `lint` path stays offline.

### Modified Capabilities
- `schema-validation`: `SchemaLoader` additionally binds stored **functions**
  from the schema file (new optional `functions` section), so KQL101 stops
  flagging known user-defined functions as unknown. Absent the section, and
  absent `--schema`, behaviour is unchanged.

## Impact

- **Code**: New `SchemaPull.cs` (REST fetch + JSON map + writers) and a `pull`
  dispatch branch in `Program.cs` (mirrors `fmt`). `SchemaLoader` extended to
  build `FunctionSymbol`s. New source-gen JSON contexts for the response and the
  extended schema file.
- **CLI surface**: New `pull` subcommand and its flags. No change to `lint`,
  `fmt`, existing flags, or exit codes. The `--schema` file gains an optional,
  backward-compatible `functions` key.
- **Dependencies**: None added. Still NativeAOT, .NET 8, offline `lint`. `pull`
  uses only `System.Net.Http` + source-gen `System.Text.Json` from the BCL.
- **Security**: The token is read from a flag/env/stdin, never logged, and used
  only as an `Authorization: Bearer` header over HTTPS to the user-named cluster.
- **Tests**: A self-check parsing a captured `.show database schema as json`
  fixture into a schema file, asserting tables + functions round-trip and that a
  query calling a pulled function no longer reports KQL101. No network in tests.
