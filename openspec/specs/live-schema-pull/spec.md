# live-schema-pull Specification

## Purpose
TBD - created by archiving change live-schema-pull. Update Purpose after archive.
## Requirements
### Requirement: Opt-in live schema pull subcommand

The system SHALL provide a `pull` subcommand that fetches a live cluster's schema
and writes it to a file in the `--schema` format consumed by offline analysis.
Invocation SHALL be `kql-guard pull --cluster <uri> --database <db> [-o <file>]`,
writing to `schemas.json` when `-o` is omitted. The `pull` subcommand SHALL be
the only path that performs a network call; the `lint` and `fmt` paths SHALL
remain fully offline and unchanged. `pull` SHALL NOT be triggered implicitly by
any other command.

#### Scenario: Pull writes a schema file the linter can consume

- **WHEN** `kql-guard pull --cluster https://c.kusto.windows.net --database DB -o schemas.json` runs successfully
- **THEN** `schemas.json` is written in the `--schema` format, and a subsequent `kql-guard q.kql --schema schemas.json` binds against it offline with no network call

#### Scenario: Lint remains offline

- **WHEN** any command other than `pull` runs
- **THEN** the system makes no network call, database connection, or auth request

### Requirement: Bearer-token authentication supplied by the caller

The `pull` subcommand SHALL authenticate using a bearer token supplied via the
`--token` flag or the `KQL_GUARD_TOKEN` environment variable, sent as an
`Authorization: Bearer` header over HTTPS to the cluster named by `--cluster`.
The system SHALL NOT perform interactive sign-in, device-code flow, or link an
Azure identity SDK. The token SHALL NOT be written to stdout, stderr, logs, or
the output file. When no token is provided, `pull` SHALL print a usage error and
exit `2`.

#### Scenario: Missing token is a usage error

- **WHEN** `pull` runs with neither `--token` nor `KQL_GUARD_TOKEN` set
- **THEN** the system prints a usage error and exits `2`, making no network call

#### Scenario: Token is never disclosed

- **WHEN** `pull` runs with a token and later fails (e.g. a non-2xx response)
- **THEN** the token value appears in no message, log line, or written file

### Requirement: Fetch schema over the Kusto REST API without an SDK

The `pull` subcommand SHALL retrieve the schema by issuing
`POST <cluster>/v1/rest/mgmt` with a JSON body `{"db":<database>,"csl":".show
database schema as json"}`, parsing the response with source-generated
`System.Text.Json`. The system SHALL NOT take a dependency on
`Microsoft.Azure.Kusto.Data` or any reflection-based client, so the NativeAOT
single-binary build is preserved. A non-2xx response or transport failure SHALL
exit `1` with a clear diagnostic.

#### Scenario: Fetch failure is reported

- **WHEN** the cluster returns a non-success HTTP status or the request fails to connect
- **THEN** the system exits `1` with a message identifying the failure and does not write a partial schema file

#### Scenario: Build remains NativeAOT

- **WHEN** the project is published with NativeAOT
- **THEN** it builds into a single binary with no added package dependency for `pull`

### Requirement: Captured stored functions are written and bound

The pulled schema SHALL include the database's stored functions, and the written
schema file SHALL carry them in an additive `functions` section. When such a file
is supplied via `--schema`, the system SHALL bind those functions so that a query
calling a user-defined function does not report `KQL101`. A query referencing a
column or table absent from the schema SHALL still report `KQL101`.

#### Scenario: A call to a pulled function is not flagged

- **WHEN** a query invokes a user-defined function present in the pulled schema file
- **THEN** no `KQL101` finding is produced for that function reference

#### Scenario: Unknown references are still flagged

- **WHEN** a query references a column or table absent from the pulled schema file
- **THEN** a `KQL101` finding is still produced

### Requirement: Optional live table-size factors

The `pull` subcommand SHALL, when `--with-sizes <file>` is given, also fetch
per-table data sizes and write a `--table-sizes`-format map `{"Table":factor}`,
where `factor` is an integer `max(1, round(size / baseline))` and `baseline`
defaults to the median table size or the `--size-baseline <bytes>` value. The
written file SHALL drive the existing `TableSizeEnricher` with no change to the
scoring pipeline. When `--with-sizes` is omitted, no size fetch SHALL occur.

#### Scenario: Sizes file scales cost as usual

- **WHEN** `pull --with-sizes sizes.json` writes factors and `lint --table-sizes sizes.json` runs on a scan of a large table
- **THEN** that table's KQL003/KQL008 weight is scaled by its factor, exactly as a hand-authored `--table-sizes` file would

#### Scenario: Sizes are opt-in

- **WHEN** `pull` runs without `--with-sizes`
- **THEN** no table-size command is issued and no sizes file is written

