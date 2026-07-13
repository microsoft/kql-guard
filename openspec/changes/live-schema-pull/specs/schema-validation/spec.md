## MODIFIED Requirements

### Requirement: Opt-in schema-aware validation

The system SHALL accept an optional `--schema <file>` flag whose JSON supplies a
database schema. The system SHALL accept two backward-compatible forms: the
existing bare map of tables to column lists
(`{"Table":[{"name":"Col","type":"string"}]}`), and an object form
(`{"tables":{"Table":[{"name","type"}]}, "functions":[{"name","parameters","body"}]}`)
that additionally carries stored functions. When supplied, the system SHALL bind
those tables **and functions** and semantically analyze each query, reporting
unknown-column, unknown-table, and unknown-function references as rule `KQL101`
(error). A reference to a function present in the schema's `functions` section
SHALL NOT be reported as `KQL101`. Without the flag, behaviour SHALL be unchanged
and fully offline (no semantic analysis).

#### Scenario: Unknown column is flagged

- **WHEN** `kql-guard q.kql --schema schemas.json` runs on a query referencing a column not in the supplied table
- **THEN** a `KQL101` error is reported at the column position

#### Scenario: Valid query against schema passes

- **WHEN** every column/table in the query exists in the schema
- **THEN** no `KQL101` finding is produced

#### Scenario: A call to a supplied function is not flagged

- **WHEN** the schema file uses the object form and a query calls a function listed in its `functions` section
- **THEN** no `KQL101` finding is produced for that function reference

#### Scenario: The bare-map form still works

- **WHEN** `--schema` is given a legacy bare `{"Table":[...]}` map with no functions
- **THEN** tables bind as before and no error is caused by the absent functions section

#### Scenario: No schema means no semantic findings

- **WHEN** `--schema` is omitted
- **THEN** no `KQL101` finding is produced and analysis stays offline
