## Tasks

- [x] Add `KQL101` (UnknownColumnOrTable, error, weight 0) to `Rules.All`.
- [x] `SchemaLoader.cs`: load JSON → `GlobalState` with one DatabaseSymbol of TableSymbols.
- [x] `--schema` arg parsing; thread GlobalState into `AnalyzeFile`; ParseAndAnalyze + map semantic errors to KQL101.
- [x] `Dictionary<string,List<SchemaColumn>>` in JSON source-gen context.
- [x] Sample + run-tests.sh case (unknown column flagged, valid passes).
- [x] README + PRD/FRD/TRS.
