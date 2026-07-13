# KQL Guard for Azure Pipelines

Lint your Kusto Query Language (KQL) detection rules for **syntax errors** and
**performance anti-patterns** as part of your pipeline. KQL Guard runs the same
offline analyzer as the [kql-guard](https://github.com/microsoft/kql-guard)
GitHub Action and emits **SARIF v2.1.0**.

## Usage

```yaml
- task: KqlGuard@1
  inputs:
    path: 'detections'          # file or dir (default '.')
```

The task downloads the binary, runs it, uploads the SARIF as a
`CodeAnalysisLogs` artifact, and logs each finding inline as a build
warning/error. It is advisory by default — the stage stays green unless you set
`failOnViolations: true`.

### Gate the pipeline

```yaml
- task: KqlGuard@1
  inputs:
    path: 'detections'
    maxCost: '50'
    failOnViolations: true      # fail on errors or --max-cost breach
```

### Pinned version, docker mode

```yaml
- task: KqlGuard@1
  inputs:
    mode: 'docker'
    version: 'v1.2.0'
    path: 'detections'
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `path` | `.` | File or directory to scan (recursive for `*.kql`). |
| `mode` | `download` | `download` (release asset), `docker` (ghcr image), or `prebuilt` (local binary). |
| `version` | `latest` | Release/image tag for download and docker modes. |
| `format` | `sarif` | `sarif`, `text`, or `json`. |
| `maxCost` | — | Fail when a query's estimated cost exceeds this value. |
| `schema` | — | Path to a `schema.json` for schema-aware validation. |
| `args` | — | Raw arguments appended verbatim (e.g. `--strict`). |
| `workingDirectory` | pipeline dir | Directory to run from. |
| `failOnViolations` | `false` | Fail the task on exit code 1. |
| `prebuiltPath` | — | prebuilt mode: path to the local binary. |
| `publishSarifArtifact` | `true` | Publish the `CodeAnalysisLogs` artifact. |
| `logIssues` | `true` | Emit each finding as an inline build issue. |

Outputs: `exitCode` and `sarifFile` (reference via the step's name, e.g.
`$(kqlguard.exitCode)`).

## Viewing results

Findings always appear **inline** as build warnings/errors. For a dedicated
**Scans** tab, install the free
[SARIF SAST Scans Tab](https://marketplace.visualstudio.com/items?itemName=sariftools.scans)
extension — it renders the `CodeAnalysisLogs` artifact this task publishes.
