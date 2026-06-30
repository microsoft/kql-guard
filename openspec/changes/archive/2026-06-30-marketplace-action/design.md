## Context

The action is a composite (not Docker/JS) so it can branch across install modes in shell while staying a single published unit. Release assets are named `kql-guard-<rid>` (and `.exe` on Windows). The ghcr image is `ghcr.io/microsoft/kql-guard`.

## Mode selection

A single `mode` input, validated to `download|docker|prebuilt`; anything else fails fast. Each mode resolves a runnable command, then a shared final step invokes it with the assembled arguments.

### download (default)
Map `${{ runner.os }}` + `${{ runner.arch }}` → asset:

| OS / arch | Asset |
|-----------|-------|
| Linux / X64 | `kql-guard-linux-x64` |
| Linux / ARM64 | `kql-guard-linux-arm64` |
| macOS / ARM64 | `kql-guard-osx-arm64` |
| Windows / X64 | `kql-guard-win-x64.exe` |
| anything else | error: "unsupported runner <os>/<arch>; use mode: docker" |

Download from `https://github.com/microsoft/kql-guard/releases/download/<version>/<asset>` with `curl -fsSL`, `chmod +x`, run. `version` defaults to `latest` (resolved via the `/releases/latest` redirect) but accepts a tag.

### docker
`docker run --rm -v "$PWD":/work -w /work ghcr.io/microsoft/kql-guard:<version> <args>`. Paths are workspace-relative. `version` defaults to `latest`.

### prebuilt
Use `bin/Release/net8.0/<rid>/publish/kql-guard` (or a path override). Errors clearly if absent. This is what the repo's own CI uses pre-publish.

## Argument assembly

Build the arg list once, mode-independent: `<path>` then, if set, `--format <format>`, `--max-cost <max-cost>`, `--schema <schema>`, then raw `args` appended verbatim. SARIF is the default `format` (matches marketplace expectations); SARIF upload remains the consumer's own step.

## Outputs

- `sarif-file` — path to the written SARIF when `format=sarif` (else empty).
- `exit-code` — the CLI's exit code (0 clean / 1 violations / 2 usage).

`fail-on-violations` (default `false`) controls the gate: `false` sets `exit-code` and keeps the step green (setup-style, consumer gates downstream); `true` re-exits with the CLI code so the job fails on violations. Exit 2 (usage) always fails the step loudly regardless.

## Release matrix

Add one row to `release.yml`: `{ os: ubuntu-24.04-arm, rid: linux-arm64 }`. NativeAOT builds on the native runner (no cross-compile). Existing rows unchanged.

## Verification

A new workflow `action-modes.yml` runs the action three times against `samples/` — `mode: prebuilt` (after a build), `mode: download` (after the v0.1.0 release exists), `mode: docker` — asserting each produces SARIF and a sane `exit-code`. `prebuilt` is the always-available self-check; `download`/`docker` depend on a published release/image.

## Decisions

- **Composite, not Docker action type** — a Docker action would force every consumer through the image; composite lets `download` skip Docker entirely while still offering `docker` mode.
- **Gate is opt-in via `fail-on-violations`** — defaults to `false` (setup-style, surfacing `exit-code` is flexible); `true` fails the job on violations for consumers who want the action to gate directly.
- **`linux-arm64` only** for the new RID — the one common gap; win-arm64/osx-x64 deferred to the docker fallback + clear error.
