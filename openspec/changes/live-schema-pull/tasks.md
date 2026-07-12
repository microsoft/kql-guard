## 1. `pull` subcommand & REST fetch

- [ ] 1.1 Add a `pull` dispatch branch in `Program.Main` mirroring the `fmt`
      branch (Program.cs:28), delegating to `SchemaPull.Run(args)`.
- [ ] 1.2 Parse `pull` flags order-independently: `--cluster <uri>` (required),
      `--database <db>` (required), `-o/--out <file>` (default `schemas.json`),
      `--token <t>` / `KQL_GUARD_TOKEN` env (required), `--with-sizes <file>`
      (optional), `--size-baseline <bytes>` (optional). Missing required flag or
      token → print usage, exit `2`. Never echo the token.
- [ ] 1.3 `SchemaPull.cs`: `HttpClient` POST to `<cluster>/v1/rest/mgmt` with body
      `{"db":<db>,"csl":".show database schema as json"}` and
      `Authorization: Bearer <token>`, `Content-Type: application/json`. Fail with
      a clear message (exit `1`) on non-2xx or transport error.
- [ ] 1.4 Add source-gen `System.Text.Json` contexts for the Kusto REST response
      envelope and the inner schema JSON; extract the schema JSON from the first
      table's first cell. Verify field names against a captured fixture (task 4.1).

## 2. Schema file output & function binding

- [ ] 2.1 Map the fetched schema to the schema-file shape: tables →
      `{"name","type"}` columns (reuse `SchemaColumn`); stored functions →
      `{"name","parameters","body"}`. Write pretty JSON to `--out`.
- [ ] 2.2 Extend the schema-file format to the object form
      `{"tables":{...}, "functions":[...]}` while still accepting the current
      bare `{"Table":[...]}` map. `SchemaLoader.FromJson` detects which form it got.
- [ ] 2.3 In `SchemaLoader`, build `FunctionSymbol`s from the `functions` section
      and add them to the `DatabaseSymbol`. If full-body binding is brittle, fall
      back to signature-only registration (design Decision 5). Confirm empirically.
- [ ] 2.4 Confirm a query calling a pulled user-defined function no longer emits
      KQL101 when linted with the generated `--schema` file.

## 3. Optional table sizes (`--with-sizes`) — separable

- [ ] 3.1 Fetch table sizes via `.show tables details` (one call, all tables;
      requires Database Monitor). Extract the `TotalOriginalSize` column (bytes)
      per table; confirm the column name on the target cluster.
- [ ] 3.2 Compute `factor = max(1, round(size / baseline))`, `baseline` = median
      table size or `--size-baseline`. `ponytail:` comment naming the knob. Write
      the existing `{"Table":factor}` `--table-sizes` map to `--with-sizes`.
- [ ] 3.3 Confirm the generated file drives `TableSizeEnricher` unchanged: a big
      table scales KQL003/008 as expected via `lint --table-sizes <file>`.

## 4. Verification

- [ ] 4.1 Commit a captured `.show database schema as json` response as a test
      fixture (redacted, from a public cluster such as help.kusto.windows.net).
      Parse it offline in the self-check — no network in tests.
- [ ] 4.2 Self-check (assert-based, in `test/run-tests.sh` style): fixture →
      schema file round-trips tables + functions; a query using a pulled function
      binds clean (no KQL101); a query using an unknown column still reports KQL101.
- [ ] 4.3 Missing token and non-2xx responses exit non-zero with a clear message
      and never print the token.
- [ ] 4.4 `dotnet publish -c Release -r linux-x64` succeeds (NativeAOT) with no
      new dependency and no reflection-JSON warnings — proves the single binary
      still builds.
- [ ] 4.5 Update README: `pull` subcommand, auth (bearer token via
      `az account get-access-token`), the recommended pull-commit-lint-offline
      flow, and the extended `--schema` file `functions` section.
