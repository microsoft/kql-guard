## Why

kql-guard ships a composite action today, but it assumes a pre-built binary in `bin/Release/...` — so a marketplace consumer would have to build the tool themselves. To publish on the GitHub Actions Marketplace (the opt-in on-ramp that precedes super-linter upstreaming), the action must be self-contained and work on a fresh runner. Different consumers want different install paths: a setup-python-style binary download, a Docker image, or a locally-built binary.

## What Changes

- Rework `action.yml` into one composite action selected by a `mode` input:
  - `download` *(default)* — map `runner.os`/arch to a release asset and `curl` it (no Docker daemon needed).
  - `docker` — run `ghcr.io/microsoft/kql-guard:<version>` against the workspace.
  - `prebuilt` — run a locally-built binary (today's behaviour; used by this repo's own CI).
- Typed inputs (`path`, `format`, `max-cost`, `schema`) plus a raw `args` passthrough and `version`/`working-directory`; outputs `sarif-file` and `exit-code` (consumer decides whether violations fail the job).
- Add a `branding:` block (marketplace requirement).
- Add `linux-arm64` to the release build matrix so `download` covers linux-x64, linux-arm64, osx-arm64, win-x64. Unsupported runners get a loud error pointing at `docker` mode.

## Capabilities

### New Capabilities
- `marketplace-action`: A self-contained, multi-mode GitHub Action publishable to the Marketplace.

## Impact

- Rewrites `action.yml`; extends `.github/workflows/release.yml` (one matrix row). No product/CLI code change. A new workflow exercises all three modes. README action section updated. Marketplace publish itself is a maintainer toggle on a release.
