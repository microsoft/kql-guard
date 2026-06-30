## 1. Action rewrite

- [x] 1.1 Rewrite `action.yml`: `mode` input (download|docker|prebuilt, default download), plus `version`, `path`, `format`, `max-cost`, `schema`, `args`, `working-directory`, `fail-on-violations` (default false); `branding` block; outputs `sarif-file`, `exit-code`.
- [x] 1.2 Resolve mode: download = arch→asset map + curl; docker = run ghcr image; prebuilt = local binary path. Shared arg-assembly + run step.
- [x] 1.3 Unsupported runner under download → fail with os/arch + docker hint. Exit 2 always fails step; exit 1 fails only when `fail-on-violations`, else sets output.

## 2. Release matrix

- [x] 2.1 Add `{ os: ubuntu-24.04-arm, rid: linux-arm64 }` row to `release.yml`.

## 3. Verification workflow

- [x] 3.1 `action-modes.yml`: run the action with `mode: prebuilt` (after build) over `samples/`, assert SARIF + exit-code. (Always-available self-check.)
- [x] 3.2 Add `mode: docker` and `mode: download` jobs, gated on a published release/image.

## 4. Docs

- [x] 4.1 Update README action section: modes, inputs, outputs, examples (download default + docker).
- [x] 4.2 Validate openspec change; archive after merge.
