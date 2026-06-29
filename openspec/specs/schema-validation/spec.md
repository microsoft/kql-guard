# schema-validation Specification

## Purpose
TBD - created by archiving change schema-validation. Update Purpose after archive.
## Requirements
### Requirement: Opt-in schema-aware validation

The system SHALL accept an optional `--schema <file>` flag whose JSON maps table names to column lists (`{"Table":[{"name":"Col","type":"string"}]}`). When supplied, the system SHALL bind those tables and semantically analyze each query, reporting unknown-column and unknown-table references as rule `KQL101` (error). Without the flag, behaviour SHALL be unchanged and fully offline (no semantic analysis).

#### Scenario: Unknown column is flagged

- **WHEN** `kql-guard q.kql --schema schemas.json` runs on a query referencing a column not in the supplied table
- **THEN** a `KQL101` error is reported at the column position

#### Scenario: Valid query against schema passes

- **WHEN** every column/table in the query exists in the schema
- **THEN** no `KQL101` finding is produced

#### Scenario: No schema means no semantic findings

- **WHEN** `--schema` is omitted
- **THEN** no `KQL101` finding is produced and analysis stays offline

