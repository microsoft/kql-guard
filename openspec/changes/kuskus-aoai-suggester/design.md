# Design notes

Full design: session artifact `2026-07-20-kuskus-aoai-suggester-design.md`.
Key decisions captured here for the repo record:

- **Two boundary crossings.** (1) Kuskus→runner already masks identifiers/
  literals in `scratch/`. (2) runner→model: Approach A sends only the masked
  signature (public-safe), so a public endpoint + default retention is correct.
  The real-text version changes crossing #2's payload and needs private + ZDR.
- **Mechanical id.** The adapter parses `CostRules.cs` for the next free `KQL0NN`
  and injects it; the model never picks the id (root-causes the PR #38 collision).
- **Structured outputs.** `json_schema` guarantees parseable JSON; the adapter
  still validates semantically (level/weight/slug/analyzer-block template + id).
- **Fail-closed + degrade-to-green.** Adapter: nonzero + empty stdout on any
  error. `run-mining.sh`: turn that into a summary skip line + exit 0, since
  calibration (the primary value) already ran and fail-closed already prevents a
  bad PR. `validate-candidate.sh` remains the second wall.
- **stdlib only.** `urllib` for IMDS + AOAI; zero new runner deps.
