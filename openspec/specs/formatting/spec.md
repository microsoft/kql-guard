# formatting Specification

## Purpose
TBD - created by archiving change kql-formatter. Update Purpose after archive.
## Requirements
### Requirement: Deterministic KQL formatting

The system SHALL format KQL using the official `Kusto.Language` formatter with a canonical one-pipe-per-line layout. Formatting SHALL be idempotent: formatting already-formatted output SHALL produce identical text. The system SHALL NOT implement its own pretty-printer.

#### Scenario: Unformatted query is normalized

- **WHEN** `kql-guard fmt q.kql` runs on `SecurityEvent|where x==1|take 5`
- **THEN** each pipe operator appears on its own line with single-spaced tokens

#### Scenario: Formatting is idempotent

- **WHEN** already-formatted KQL is formatted again
- **THEN** the output is byte-identical to the input

### Requirement: Write and check modes

The `fmt` subcommand SHALL default to printing formatted output to stdout. With `--write`, it SHALL rewrite each file in place. With `--check`, it SHALL exit non-zero if any file is not already formatted (a CI gate) and SHALL NOT modify files. `--write` and `--check` SHALL be mutually exclusive.

#### Scenario: Check fails on unformatted file

- **WHEN** `fmt <path> --check` finds an unformatted file
- **THEN** the tool prints `would reformat <path>` and exits 1

#### Scenario: Write makes check pass

- **WHEN** `fmt <path> --write` is run, then `fmt <path> --check`
- **THEN** the second invocation exits 0

