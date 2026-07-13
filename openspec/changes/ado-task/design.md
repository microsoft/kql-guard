## Context

kql-guard already meets GitHub CI users where they are via a composite bash
**GitHub Action** (`action.yml`): three acquisition modes (`download` release
asset by OS/arch, `docker` `ghcr.io/microsoft/kql-guard:<version>`, `prebuilt`
local binary), typed inputs (`path`, `mode`, `version`, `format`, `max-cost`,
`schema`, `args`, `working-directory`, `fail-on-violations`, `prebuilt-path`),
outputs `sarif-file`/`exit-code`, and a gate: CLI exit `2` fails loudly always,
exit `1` fails the job only when `fail-on-violations=true`, else just sets the
output. When `format=sarif` the CLI writes SARIF to **stdout**, which the Action
redirects to `kql-guard-results.sarif` (there is no `--sarif-output` flag).

Azure DevOps pipelines cannot consume a GitHub Action. This change adds an
**Azure DevOps Marketplace task** that reproduces that contract for ADO. Two ADO
realities shape the design: (1) an ADO task's handler is a **Node script**, not
bash, so the 3-mode logic is reimplemented in TypeScript; and (2) ADO has **no
native SARIF ingestion**, so findings must be surfaced explicitly. The de-facto
ADO convention is to publish SARIF as a build artifact named `CodeAnalysisLogs`,
which the free *SARIF SAST Scans Tab* Marketplace extension renders as a Scans
tab; inline visibility additionally uses `##vso[task.logissue …]`.

## Goals / Non-Goals

**Goals:**
- Ship `KqlGuard@1`, a packaged ADO task, with **full parity** to the GitHub
  Action's three modes and its input/output/gate contract.
- Surface SARIF **both** as a `CodeAnalysisLogs` artifact (Scans tab) and as
  per-finding inline build issues, toggleable independently.
- Build to a `.vsix` with `tfx-cli` and publish from a `v*`-tagged workflow,
  reusing the same release assets/image the Action already consumes.
- Keep the handler a thin wrapper: reuse the platform task libraries, add no
  gratuitous abstraction, and cover the logic with an `assert`-only self-check.

**Non-Goals:**
- No change to the .NET analyzer, its CLI, exit codes, `action.yml`, or the
  NativeAOT zero-runtime-dependency pillar. The task shells out to the same
  binary/image.
- No second ADO task for live schema `pull`, no telemetry, no custom extension
  UI (task.json auto-generates the input form), and no mapping of SARIF into the
  Tests/Coverage tabs — the Scans tab plus inline issues is the surface.
- No hand-rolled input parser — the blessed `azure-pipelines-task-lib` does it
  with less code. (The release download is a few lines of stdlib `fetch`, not a
  dependency; see Decision 2.)
- No on-prem Azure DevOps **Server** (Node16) target unless later requested; the
  handler is Node20 (Decision 2).

## Decisions

**1. Packaged Marketplace task, not a YAML template.** A shareable
`azure-pipelines.yml` template would be lighter, but the user chose a packaged
extension for a true Marketplace-installable `- task: KqlGuard@1` that mirrors
`uses: microsoft/kql-guard@v1`. So the deliverable is a `vss-extension.json`
extension bundling one build task. `ponytail:` scope is fixed by the user;
laziness applies to *how* — a thin Node wrapper over the existing binary, not a
reimplementation of any analysis.

**2. Node20 handler + platform task libraries.** `task.json` declares an
`execution: { Node20_1: { target: "index.js" } }` handler. The handler uses
`azure-pipelines-task-lib` for typed input reading (`getInput`/`getBoolInput`/
`getPathInput`), result setting (`setResult`), artifact upload (`uploadArtifact`),
and issue logging. The `download` mode fetches the release asset with the Node
stdlib `fetch` (redirects followed) — not `azure-pipelines-tool-lib`, whose
pinned transitive `uuid@3` carries a security advisory and which we would pull in
for a single function. Rationale: task-lib is the Microsoft-maintained,
AOT-irrelevant (Node) building block for inputs/results; the one download we need
is a few stdlib lines, so no second dependency earns its keep. Node20 is the
current ADO hosted-agent runtime; Node16 is only needed for older on-prem Server,
which the user did not request.

**3. Reimplement the 3 modes in the handler, do not re-derive analysis.** The
handler computes the OS/arch → asset name exactly as the Action does
(`kql-guard-linux-x64`, `kql-guard-linux-arm64`, `kql-guard-osx-arm64`,
`kql-guard-win-x64.exe`) and the URL
`https://github.com/microsoft/kql-guard/releases/{latest/download|download/<version>}/<asset>`
for `download`; runs `docker run … ghcr.io/microsoft/kql-guard:<version>` mounting
the workspace for `docker`; and executes `prebuiltPath` (default the Action's
`bin/Release/net8.0/linux-x64/publish/kql-guard`) for `prebuilt`. On an
unsupported OS/arch under `download`, it fails naming the os/arch and pointing at
`mode: docker` — same message contract as the Action. Argument assembly
(`path`, `--format`, `--max-cost`, `--schema`, raw `args`) is one shared
function, unit-tested; SARIF has no output flag, so in `format=sarif` the handler
**captures the tool's stdout** to `kql-guard-results.sarif` (the Action's `>`
redirect), otherwise stdout streams to the log.

**4. Surface SARIF two independent ways, both on by default.** After a
`format=sarif` run, the handler reads `kql-guard-results.sarif` from the working
directory. If `publishSarifArtifact` (default `true`), it uploads that file as an
artifact whose **name is `CodeAnalysisLogs`** (the SARIF SAST Scans Tab
extension's required artifact name). If `logIssues` (default `true`), it parses
`results[]` and emits, per finding,
`##vso[task.logissue type=<error|warning>;sourcepath=<uri>;linenumber=<startLine>;columnnumber=<startColumn>]<ruleId>: <message.text>`
via `tl.command('task.logissue', props, msg)`. SARIF `level: error` → `type=error`,
`warning` → `type=warning`. The two paths are independent so a consumer can keep
inline issues while disabling the artifact, or vice-versa. `ponytail:` no SARIF
transformation library — the emitter is our own (`SarifModels.cs`), so we parse
exactly the shape we produce.

**5. Map the exit-code gate to ADO task results, preserving Action semantics.**
The handler captures the CLI exit code (`ignoreReturnCode`, sets output
`exitCode`) and maps: `2` → `setResult(Failed, …, done=true)` **always** (usage
error, loud); `1` → `Failed` if `failOnViolations` else `SucceededWithIssues`
(the ADO analogue of "set output, don't fail"); `0` → `Succeeded`. A non-launch
error (asset 404, docker/image error, transport) is a task failure with a clear
message. This is the exact gate table from `action.yml`, translated to ADO's
three-state result model. `SucceededWithIssues` (yellow) is the closest ADO has
to "advisory violations" and is the default when `failOnViolations=false`.

**6. Build/package with `tfx-cli`; publish from a tagged workflow, secrets-gated.**
`azure-devops/package.json` scripts compile `index.ts`→`index.js` (`tsc`), run
the self-test, then `tfx extension create` → `.vsix`. A new
`.github/workflows/publish-ado-extension.yml` runs on `v*` tags and manual
dispatch: `npm ci` → `tsc` → self-test → `tfx extension create`, always uploading
the `.vsix` as a build artifact, and running `tfx extension publish` **only when**
the `VS_MARKETPLACE_TOKEN` (and publisher id) secrets are present — otherwise the
publish step is skipped, not failed. `ponytail:` this mirrors the existing
`action-modes.yml` `mode=download` non-blocking pattern for a private repo whose
public release/Marketplace identity is not yet provisioned. The `.vsix` artifact
means every tagged build is installable manually even before Marketplace
publishing is wired.

**7. Repository layout: a self-contained `azure-devops/` directory.** All task
code, its `package.json`/`node_modules`, `tsconfig.json`, and the manifest live
under `azure-devops/`, isolated from the .NET solution so the Node toolchain
never touches the analyzer build. The task folder `KqlGuardTask/` holds
`task.json` (input schema + Node20 handler declaration), `index.ts`, and
`test.js`. `ponytail:` co-locate the icon and `overview.md` the Marketplace
manifest references; no separate assets pipeline.

**8. Inputs mirror the Action, camelCased, plus two ADO toggles.** `task.json`
declares `path` (default `.`), `mode` (pickList download/docker/prebuilt, default
`download`), `version` (default `latest`), `format` (pickList sarif/text/json,
default `sarif`), `maxCost`, `schema`, `args`, `workingDirectory`,
`failOnViolations` (bool, default `false`), `prebuiltPath`, `publishSarifArtifact`
(bool, default `true`), `logIssues` (bool, default `true`). Names track the
Action inputs so the README's two usage sections stay parallel. `version=latest`
matches the Action's default and the `releases/latest/download/` URL form.

## Risks / Trade-offs

- **`tl.uploadArtifact` container/name contract** → the Scans tab keys off the
  artifact *name* `CodeAnalysisLogs`; assert the exact literal in the self-test
  and document that the org must install the (free) SARIF SAST Scans Tab
  extension to see the tab. Inline issues need no extra extension, so findings
  are never invisible.
- **`##vso[task.logissue]` field support** → `sourcepath`/`linenumber`/
  `columnnumber` are honored for build (not release) pipelines; the message text
  always carries `ruleId + file:line` so a finding is legible even where the
  editor-link metadata is ignored. Parse-map covered by the fixture test.
- **Marketplace identity is a placeholder** → `publisher`/extension id/task GUID
  are placeholders a maintainer sets before first publish; the `.vsix` still
  builds and installs manually. Non-blocking for this change.
- **Node20 vs on-prem Server** → hosted agents run Node20; if a consumer needs
  Azure DevOps Server, add a `Node16` execution target later — additive, no
  redesign.
- **Docker mode on Windows/macOS agents** → same constraint as the Action
  (`docker` mode assumes a working Docker daemon on the agent); documented, not
  worked around.

## Migration Plan

Purely additive. New `azure-devops/` tree and one new workflow; nothing in the
.NET build, `action.yml`, existing workflows, or CLI changes. Consumers opt in
by installing the extension and adding `- task: KqlGuard@1`. Rollback = remove
`azure-devops/` and the publish workflow; no other artifact references them.

## Open Questions

None blocking. Deferred, non-blocking items with chosen defaults: (1) Marketplace
`publisher`/extension-id/task-GUID are placeholders until a maintainer
provisions the Marketplace identity; (2) Node20 handler (add Node16 only if
on-prem Azure DevOps Server support is later requested); (3) `version` defaults
to `latest`, matching the Action.
