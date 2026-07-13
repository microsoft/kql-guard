## 1. Scaffold the `azure-devops/` extension

- [ ] 1.1 Create `azure-devops/package.json` (private, name `kql-guard-ado`) with
      dev-deps `azure-pipelines-task-lib`, `azure-pipelines-tool-lib`,
      `typescript`, `@types/node`, `tfx-cli`, and scripts: `build` (`tsc`),
      `test` (`node KqlGuardTask/test.js`), `package` (`tfx extension create`).
- [ ] 1.2 Add `azure-devops/tsconfig.json` targeting Node20 (CommonJS, `outDir`
      the task folder, `strict`), compiling `KqlGuardTask/index.ts` → `index.js`.
- [ ] 1.3 Add `azure-devops/.gitignore` for `node_modules/`, `*.vsix`, and the
      generated `KqlGuardTask/index.js`/`*.js.map` (built in CI/package step).

## 2. Task definition (`KqlGuardTask/task.json`)

- [ ] 2.1 Declare the task: id (placeholder GUID), `name: KqlGuard`, friendly
      name, `version {Major:1,Minor:0,Patch:0}`, category `Utility`, and a
      `Node20_1` execution target `index.js`.
- [ ] 2.2 Declare inputs mirroring the Action (camelCased): `path` (default `.`),
      `mode` (pickList download/docker/prebuilt, default `download`), `version`
      (default `latest`), `format` (pickList sarif/text/json, default `sarif`),
      `maxCost`, `schema`, `args`, `workingDirectory`, `failOnViolations` (bool,
      default `false`), `prebuiltPath`, plus `publishSarifArtifact` (bool, default
      `true`) and `logIssues` (bool, default `true`). Add `visibleRule`s so
      `version` shows for download/docker and `prebuiltPath` for prebuilt.

## 3. Handler: acquisition modes (`KqlGuardTask/index.ts`)

- [ ] 3.1 `download` mode: map `process.platform`/`process.arch` → asset name
      (`kql-guard-linux-x64`, `kql-guard-linux-arm64`, `kql-guard-osx-arm64`,
      `kql-guard-win-x64.exe`); build the release URL
      (`releases/latest/download/<asset>` or `releases/download/<version>/<asset>`);
      `toolLib.downloadTool`, `chmod +x` on POSIX, return the local path. On an
      unsupported os/arch, fail naming the os/arch and pointing at `mode: docker`.
- [ ] 3.2 `docker` mode: run `docker run --rm -v <workspace>:/src -w /src
      ghcr.io/microsoft/kql-guard:<version>` with the assembled args; treat a
      docker/image error as a task failure with a clear message.
- [ ] 3.3 `prebuilt` mode: resolve `prebuiltPath` (default
      `bin/Release/net8.0/linux-x64/publish/kql-guard`); fail clearly if the
      binary is absent.
- [ ] 3.4 Shared arg-assembly function: from inputs build the CLI argv
      (`path`, `--format`, `--max-cost`, `--schema`, then raw `args` passthrough).
      Run under `workingDirectory` with `ignoreReturnCode` to capture the exit
      code; when `format=sarif`, capture the tool's stdout to
      `kql-guard-results.sarif` (the Action's `>` redirect — no `--sarif-output`
      flag), otherwise let stdout stream to the log.

## 4. Handler: SARIF surfacing & gate

- [ ] 4.1 After a `format=sarif` run, locate `kql-guard-results.sarif` in the
      working directory and set output `sarifFile` to its path.
- [ ] 4.2 If `publishSarifArtifact`, `tl.uploadArtifact('CodeAnalysisLogs',
      <sarifPath>, 'CodeAnalysisLogs')` — assert the literal artifact name so the
      SARIF SAST Scans Tab extension picks it up.
- [ ] 4.3 If `logIssues`, parse `results[]` and emit one
      `##vso[task.logissue type=<error|warning>;sourcepath=<uri>;linenumber=<startLine>;columnnumber=<startColumn>]<ruleId>: <text>`
      per finding via `tl.command('task.logissue', props, msg)`; SARIF
      `level: error`→`error`, else `warning`.
- [ ] 4.4 Gate mapping → `tl.setResult`: exit `2` → `Failed` always (usage,
      loud); exit `1` → `Failed` if `failOnViolations` else `SucceededWithIssues`;
      exit `0` → `Succeeded`. Always set output `exitCode`. A non-launch error
      (404/docker/transport) → `Failed` with a clear message.

## 5. Self-test (`KqlGuardTask/test.js`, assert-only)

- [ ] 5.1 Export the pure helpers from `index.ts` (arg assembly, os/arch→asset,
      SARIF→logissue lines, exit-code→result) so they are unit-testable without a
      live agent.
- [ ] 5.2 Assert arg assembly for representative inputs (default; sarif+maxCost+
      schema; raw `args` passthrough) and os/arch→asset for all four supported
      targets + a clear failure for an unsupported one.
- [ ] 5.3 Parse a committed SARIF fixture (reuse/emit the analyzer's own SARIF
      shape) and assert the exact `##vso[task.logissue …]` lines and the
      exit-code→task-result mapping (0/1 with both `failOnViolations` values/2).
- [ ] 5.4 Wire `node KqlGuardTask/test.js` into `azure-devops/package.json`
      `test`; it must pass with no network and no ADO agent.

## 6. Marketplace manifest & assets

- [ ] 6.1 `azure-devops/vss-extension.json`: publisher (placeholder), extension
      id/name/version, `categories: ["Azure Pipelines"]`, `targets` Azure
      Pipelines, `contributions` of type `ms.vss-distributed-task.task` pointing
      at `KqlGuardTask`, `files` (task folder + icon), and `content` →
      `overview.md`.
- [ ] 6.2 Add `azure-devops/overview.md` (Marketplace listing: what it does, the
      YAML usage snippets, the one-time SARIF SAST Scans Tab prerequisite) and a
      128×128 `azure-devops/images/kql-guard.png` icon.

## 7. Publish workflow

- [ ] 7.1 Add `.github/workflows/publish-ado-extension.yml` on `push` tags `v*`
      and `workflow_dispatch`: checkout, setup-node 20, `npm ci`, `npm run build`,
      `npm test`, `tfx extension create` (→ `.vsix`), always upload the `.vsix`
      as a workflow artifact.
- [ ] 7.2 Add a final `tfx extension publish` step gated on the presence of
      `secrets.VS_MARKETPLACE_TOKEN` (+ publisher id); skip (do not fail) when
      absent, mirroring the `action-modes.yml` non-blocking pattern. `ponytail:`
      comment naming the gate.

## 8. Verification & docs

- [ ] 8.1 `npm ci && npm run build && npm test` in `azure-devops/` passes; `tfx
      extension create` produces a `.vsix` locally.
- [ ] 8.2 Confirm the .NET build/tests are untouched: `./test/run-tests.sh` and
      `dotnet publish -c Release -r linux-x64` still pass (no cross-impact from
      the Node toolchain).
- [ ] 8.3 Add an "Azure DevOps" section to `README.md` mirroring the "GitHub
      Action" section: the `KqlGuard@1` usage snippets (minimal, gate, schema,
      prebuilt, docker, outputs) and the one-time org-extension prerequisites.
