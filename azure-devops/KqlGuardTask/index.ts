import fs = require('fs');
import path = require('path');
import tl = require('azure-pipelines-task-lib/task');

// ---------------------------------------------------------------------------
// Pure helpers — exported for the self-test (KqlGuardTask/test.js). No I/O.
// ---------------------------------------------------------------------------

export interface ScanInputs {
  path: string;
  format: string;
  maxCost: string;
  schema: string;
  args: string;
}

/** Split a raw args string on whitespace, honoring simple single/double quotes. */
export function splitArgs(raw: string): string[] {
  const out: string[] = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(raw)) !== null) {
    out.push(m[1] ?? m[2] ?? m[3]);
  }
  return out;
}

/**
 * Build the kql-guard CLI argv (excludes the binary itself). SARIF is captured
 * from stdout, so there is no output-file flag here — mirrors action.yml.
 */
export function buildArgs(i: ScanInputs): string[] {
  const argv: string[] = [i.path];
  if (i.format) argv.push('--format', i.format);
  if (i.maxCost) argv.push('--max-cost', i.maxCost);
  if (i.schema) argv.push('--schema', i.schema);
  if (i.args && i.args.trim()) argv.push(...splitArgs(i.args));
  return argv;
}

const ASSETS: { [key: string]: string } = {
  'linux/x64': 'kql-guard-linux-x64',
  'linux/arm64': 'kql-guard-linux-arm64',
  'darwin/arm64': 'kql-guard-osx-arm64',
  'win32/x64': 'kql-guard-win-x64.exe',
};

/** Map a Node platform/arch to the release asset name, or null if unsupported. */
export function assetFor(platform: string, arch: string): string | null {
  return ASSETS[`${platform}/${arch}`] ?? null;
}

/** Build the release download URL for an asset and version. */
export function downloadUrl(asset: string, version: string): string {
  const base = 'https://github.com/microsoft/kql-guard/releases';
  return version === 'latest'
    ? `${base}/latest/download/${asset}`
    : `${base}/download/${version}/${asset}`;
}

export interface LogIssue {
  type: 'error' | 'warning';
  sourcepath?: string;
  linenumber?: number;
  columnnumber?: number;
  message: string;
}

/** Parse a SARIF log into one ADO logissue record per result. */
export function sarifToIssues(sarif: any): LogIssue[] {
  const issues: LogIssue[] = [];
  for (const run of sarif?.runs ?? []) {
    for (const r of run?.results ?? []) {
      const loc = r?.locations?.[0]?.physicalLocation;
      const uri = loc?.artifactLocation?.uri;
      const region = loc?.region;
      const prefix = r?.ruleId ? `${r.ruleId}: ` : '';
      const issue: LogIssue = {
        type: r?.level === 'error' ? 'error' : 'warning',
        message: `${prefix}${r?.message?.text ?? ''}`,
      };
      if (uri) issue.sourcepath = uri;
      if (region?.startLine != null) issue.linenumber = region.startLine;
      if (region?.startColumn != null) issue.columnnumber = region.startColumn;
      issues.push(issue);
    }
  }
  return issues;
}

export type ScanResult = 'Succeeded' | 'SucceededWithIssues' | 'Failed';

/** Map a kql-guard exit code to an ADO task result (mirrors action.yml gate). */
export function resultForExit(exitCode: number, failOnViolations: boolean): ScanResult {
  if (exitCode === 0) return 'Succeeded';
  if (exitCode === 2) return 'Failed'; // usage error — always loud
  return failOnViolations ? 'Failed' : 'SucceededWithIssues'; // exit 1 = violations
}

// ---------------------------------------------------------------------------
// Handler — runs only when invoked as the task entrypoint.
// ---------------------------------------------------------------------------

async function run(): Promise<void> {
  try {
    const inputs = {
      path: tl.getInput('path') || '.',
      mode: tl.getInput('mode') || 'download',
      version: tl.getInput('version') || 'latest',
      format: (tl.getInput('format') || 'sarif').toLowerCase(),
      maxCost: tl.getInput('maxCost') || '',
      schema: tl.getInput('schema') || '',
      args: tl.getInput('args') || '',
      workingDirectory: tl.getPathInput('workingDirectory', false, false) || process.cwd(),
      failOnViolations: tl.getBoolInput('failOnViolations'),
      prebuiltPath: tl.getInput('prebuiltPath') || '',
      publishSarifArtifact: tl.getBoolInput('publishSarifArtifact'),
      logIssues: tl.getBoolInput('logIssues'),
    };

    const cwd = inputs.workingDirectory;
    const argv = buildArgs(inputs);

    // Resolve the executable + any leading args (docker) per mode.
    let tool: string;
    let leading: string[] = [];
    switch (inputs.mode) {
      case 'download': {
        const asset = assetFor(process.platform, process.arch);
        if (!asset) {
          tl.setResult(tl.TaskResult.Failed,
            `Unsupported agent ${process.platform}/${process.arch} for mode: download. Use mode: docker instead.`);
          return;
        }
        const toolLib = require('azure-pipelines-tool-lib/tool');
        const url = downloadUrl(asset, inputs.version);
        console.log(`Downloading ${url}`);
        const downloaded: string = await toolLib.downloadTool(url);
        tool = path.join(path.dirname(downloaded), asset);
        fs.renameSync(downloaded, tool);
        if (process.platform !== 'win32') fs.chmodSync(tool, 0o755);
        break;
      }
      case 'docker': {
        tool = tl.which('docker', true);
        leading = ['run', '--rm', '-v', `${cwd}:/work`, '-w', '/work',
          `ghcr.io/microsoft/kql-guard:${inputs.version}`];
        break;
      }
      case 'prebuilt': {
        tool = inputs.prebuiltPath || 'bin/Release/net8.0/linux-x64/publish/kql-guard';
        if (!fs.existsSync(tool)) {
          tl.setResult(tl.TaskResult.Failed,
            `kql-guard binary not found at ${tool}. Build it first (dotnet publish -c Release -r linux-x64) or use mode: download.`);
          return;
        }
        break;
      }
      default:
        tl.setResult(tl.TaskResult.Failed,
          `Invalid mode '${inputs.mode}'. Expected download, docker, or prebuilt.`);
        return;
    }

    // Run, capturing stdout to the SARIF file when format=sarif (the action's
    // `> kql-guard-results.sarif` redirect — the CLI has no output-file flag).
    // ponytail: execSync buffers output; fine for a linter, revisit if a scan
    // ever streams gigabytes.
    const sarifFile = inputs.format === 'sarif' ? path.join(cwd, 'kql-guard-results.sarif') : '';
    const runner = tl.tool(tool);
    for (const a of leading) runner.arg(a);
    for (const a of argv) runner.arg(a);

    const res = runner.execSync({ cwd, silent: !!sarifFile });
    if (res.error) throw res.error;
    const exitCode = res.code;

    if (sarifFile) {
      // stdout was the SARIF and stderr the diagnostics — both silenced above,
      // so write the SARIF to the file and surface stderr to the log.
      fs.writeFileSync(sarifFile, res.stdout ?? '');
      if (res.stderr) process.stderr.write(res.stderr);
    }
    // Non-sarif: execSync already streamed stdout/stderr live.

    tl.setVariable('exitCode', String(exitCode), false, true);
    tl.setVariable('sarifFile', sarifFile, false, true);

    // Surface SARIF two independent ways.
    if (sarifFile && fs.existsSync(sarifFile)) {
      if (inputs.publishSarifArtifact) {
        // Artifact name must be the literal 'CodeAnalysisLogs' for the
        // SARIF SAST Scans Tab extension to render it.
        tl.uploadArtifact('CodeAnalysisLogs', sarifFile, 'CodeAnalysisLogs');
      }
      if (inputs.logIssues) {
        let sarif: any = null;
        try { sarif = JSON.parse(fs.readFileSync(sarifFile, 'utf8')); } catch { /* not SARIF */ }
        if (sarif) {
          for (const issue of sarifToIssues(sarif)) {
            const props: { [k: string]: string } = { type: issue.type };
            if (issue.sourcepath) props.sourcepath = issue.sourcepath;
            if (issue.linenumber != null) props.linenumber = String(issue.linenumber);
            if (issue.columnnumber != null) props.columnnumber = String(issue.columnnumber);
            tl.command('task.logissue', props, issue.message);
          }
        }
      }
    }

    // Gate — mirrors action.yml: exit 2 always fails; exit 1 gated by
    // failOnViolations; exit 0 succeeds.
    if (exitCode === 2) {
      tl.setResult(tl.TaskResult.Failed, 'kql-guard usage error (exit 2). Check the inputs.');
      return;
    }
    const result = resultForExit(exitCode, inputs.failOnViolations);
    if (result === 'Failed') {
      tl.setResult(tl.TaskResult.Failed, 'kql-guard found violations.');
    } else if (result === 'SucceededWithIssues') {
      tl.setResult(tl.TaskResult.SucceededWithIssues, 'kql-guard found violations (advisory).');
    } else {
      tl.setResult(tl.TaskResult.Succeeded, 'kql-guard passed.');
    }
  } catch (err: any) {
    tl.setResult(tl.TaskResult.Failed, err?.message ?? String(err));
  }
}

if (require.main === module) {
  run();
}
