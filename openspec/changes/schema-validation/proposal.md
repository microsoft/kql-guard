## Why

kql-guard parses syntactically but is schema-blind: it can't tell a typo'd column or a nonexistent table from a valid one. The only thing the okayql spike does better is semantic validation against real Sentinel/ADX schemas. Closing that gap makes kql-guard catch the most common detection-rule bug — referencing a field that doesn't exist — before merge, while staying fully offline.

## What Changes

- Add an opt-in `--schema schemas.json` flag. The JSON is `{ "TableName": [{"name":"Col","type":"string"}, ...] }` — the exact shape okayql's `schemaindexer.py` already emits.
- When supplied, `ParseAndAnalyze` against those tables and surface semantic errors (unknown column/table) as a new rule `KQL101`.
- No schema flag → current behaviour, unchanged and offline.

## Capabilities

### New Capabilities
- `schema-validation`: opt-in semantic checking of column/table references against a supplied schema.

## Impact

- `SchemaLoader.cs` (build GlobalState from JSON); small change in `Program.cs` AnalyzeFile + arg parsing; one `KQL101` rule entry; `Dictionary<string,List<{name,type}>>` JSON context. Self-check + sample cover unknown column. No new dependency.
