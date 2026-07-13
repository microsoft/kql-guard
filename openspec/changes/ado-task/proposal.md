## Why

kql-guard ships a GitHub Action (`action.yml`) so GitHub CI can lint KQL with
zero setup, but many detection-engineering teams run their pipelines in **Azure
DevOps**, where a GitHub Action cannot be consumed. Post-demo feedback (Partner
SWE) named an ADO equivalent as the top packaging gap. Today an ADO user must
hand-roll a `script:` step that downloads the binary, runs it, and parses the
result — exactly the boilerplate the GitHub Action removes for GitHub users.

The fix is a **packaged Azure DevOps Marketplace task extension** that mirrors
the Action's contract one-to-one: the same three acquisition modes, the same
inputs, the same exit-code gate, and — because ADO has no native SARIF
ingestion — surfaces findings **both** as an inline build issue per finding and
as a `CodeAnalysisLogs` artifact that the free *SARIF SAST Scans Tab* extension
renders as a Scans tab. This makes `- task: KqlGuard@1` as turnkey in ADO as
`uses: microsoft/kql-guard@v1` is in GitHub Actions.

## What Changes

- Add a **packaged ADO task extension** under a new `azure-devops/` directory:
  a `vss-extension.json` manifest, `overview.md`, an icon, and a single build
  task `KqlGuard` (`KqlGuardTask/`) with a Node20 handler.
- **Reimplement the Action's 3-mode acquisition in the Node handler**:
  `download` (default — fetch the release asset by OS/arch), `docker`
  (`ghcr.io/microsoft/kql-guard:<version>`), and `prebuilt` (a locally-built
  binary). Full parity with `action.yml`; no mode dropped.
- **Mirror the Action's input/output contract**: inputs `path`, `mode`,
  `version`, `format`, `maxCost`, `schema`, `args`, `workingDirectory`,
  `failOnViolations`, `prebuiltPath`, plus two ADO-only toggles
  `publishSarifArtifact` (default `true`) and `logIssues` (default `true`);
  outputs `exitCode` and `sarifFile`.
- **Surface SARIF two ways** (ADO has no built-in SARIF view): publish the
  SARIF as a build artifact named **`CodeAnalysisLogs`** (rendered by the free
  *SARIF SAST Scans Tab* extension) and emit one
  `##vso[task.logissue type=warning|error;sourcepath=…;linenumber=…;columnnumber=…]`
  per SARIF result so findings appear inline with no extra extension.
- **Map the exit-code gate to ADO task results**: CLI exit `2` (usage) →
  `Failed` always; exit `1` (violations) → `Failed` if `failOnViolations` else
  `SucceededWithIssues`; exit `0` → `Succeeded`. Same semantics as the Action.
- Add a **publish workflow** (`.github/workflows/publish-ado-extension.yml`) on
  `v*` tags + manual dispatch that builds the `.vsix` with `tfx-cli` and, when
  Marketplace secrets are present, publishes it — skipping publish (not failing)
  while secrets are absent, and always uploading the `.vsix` artifact.

## Capabilities

### New Capabilities
- `ado-task`: A packaged Azure DevOps Marketplace task (`KqlGuard@1`) that runs
  kql-guard in ADO pipelines with the same three acquisition modes and
  input/output contract as the GitHub Action, maps the exit-code gate to ADO
  task results, and surfaces SARIF both inline (per-finding build issues) and as
  a `CodeAnalysisLogs` artifact for the SARIF SAST Scans tab.

## Impact

- **New code**: `azure-devops/` — `vss-extension.json`, `overview.md`,
  `images/kql-guard.png`, `package.json`, `tsconfig.json`, and
  `KqlGuardTask/{task.json, index.ts→index.js, test.js}`. A Node20 handler using
  `azure-pipelines-task-lib` (input parsing, `setResult`, `uploadArtifact`,
  `logIssue`) and `azure-pipelines-tool-lib` (`downloadTool`). No change to the
  .NET analyzer, `action.yml`, or existing workflows.
- **CLI surface**: None. The task shells out to the same `kql-guard` binary/
  image the Action uses; the analyzer is untouched.
- **Dependencies**: Node/npm dev-time only, scoped to `azure-devops/`
  (`azure-pipelines-task-lib`, `azure-pipelines-tool-lib`, `tfx-cli`,
  `typescript`). The published task bundles its runtime deps; the .NET build and
  its zero-runtime-dependency NativeAOT pillar are unaffected.
- **Release/CI**: New `publish-ado-extension.yml`. It reuses the same release
  assets/image the Action consumes; no new binaries are produced. Publish is
  gated on Marketplace secrets and skips cleanly when they are absent (mirroring
  the existing private-repo `mode=download` non-blocking pattern).
- **Docs**: New "Azure DevOps" section in `README.md` mirroring the GitHub
  Action section, with the YAML usage snippets and the one-time org-extension
  prerequisites.
- **Tests**: A Node `assert`-only self-check (`KqlGuardTask/test.js`, matching
  the framework-free `run-tests.sh` ethos) covering argument assembly per input,
  OS/arch→asset-name mapping, SARIF→`logissue` parsing against a fixture, and
  exit-code→task-result mapping. No network, no live pipeline.
