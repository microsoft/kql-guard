using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Kusto.Language;
using Kusto.Language.Syntax;

namespace KqlGuard;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length < 1 || args[0] is "-h" or "--help")
        {
            Console.Error.WriteLine("Usage: kql-guard <path> [--format text|sarif|json] [--max-cost <int>] [--strict] [--table-sizes sizes.json]");
            Console.Error.WriteLine("       kql-guard fmt <path> [--write|--check]");
            Console.Error.WriteLine("       kql-guard pull --cluster <uri> --database <db> [-o schemas.json] [--with-sizes sizes.json]");
            Console.Error.WriteLine("  <path>          A .kql file or a directory to scan recursively.");
            Console.Error.WriteLine("  --format sarif  Emit SARIF v2.1.0 instead of text diagnostics.");
            Console.Error.WriteLine("  --max-cost <n>  Fail (exit 1) if any file's cost score exceeds n.");
            Console.Error.WriteLine("  --strict        Fail (exit 1) on any finding, including advisory cost warnings.");
            Console.Error.WriteLine("  fmt             Format KQL; --write rewrites files, --check gates CI.");
            Console.Error.WriteLine("  pull            Fetch a live cluster's schema (+ optional sizes) into a --schema file.");
            Console.Error.WriteLine("  Exit codes: 0 clean/advisory-only · 1 errors, budget breach, or --strict findings · 2 usage.");
            return args.Length < 1 ? 2 : 0;
        }

        if (args[0] == "fmt")
        {
            return Formatter.Run(args);
        }

        if (args[0] == "pull")
        {
            return SchemaPull.Run(args);
        }

        var target = args[0];
        string format = "text";
        int? maxCost = null;
        string? tableSizesPath = null;
        string? baselinePath = null;
        bool writeBaseline = false;
        string? schemaPath = null;
        bool strict = false;

        // Parse the remaining flags order-independently.
        for (int i = 1; i < args.Length; i++)
        {
            if (string.Equals(args[i], "--format", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                format = args[i + 1].ToLowerInvariant();
                if (format is not ("text" or "sarif" or "json"))
                {
                    Console.Error.WriteLine($"--format expects text|sarif|json, got: {args[i + 1]}");
                    return 2;
                }
                i++;
            }
            else if (string.Equals(args[i], "--max-cost", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                if (!int.TryParse(args[i + 1], out var parsed) || parsed < 0)
                {
                    Console.Error.WriteLine($"--max-cost expects a non-negative integer, got: {args[i + 1]}");
                    return 2;
                }
                maxCost = parsed;
                i++;
            }
            else if (string.Equals(args[i], "--table-sizes", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                tableSizesPath = args[i + 1];
                i++;
            }
            else if (string.Equals(args[i], "--baseline", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                baselinePath = args[i + 1];
                i++;
            }
            else if (string.Equals(args[i], "--write-baseline", StringComparison.OrdinalIgnoreCase))
            {
                writeBaseline = true;
            }
            else if (string.Equals(args[i], "--strict", StringComparison.OrdinalIgnoreCase))
            {
                strict = true;
            }
            else if (string.Equals(args[i], "--schema", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length)
            {
                schemaPath = args[i + 1];
                i++;
            }
            else
            {
                Console.Error.WriteLine($"Unrecognized argument: {args[i]}");
                return 2;
            }
        }

        if (!TryResolveFiles(target, out var files)) return 2;

        ICostEnricher enricher = new NullCostEnricher();
        if (tableSizesPath != null)
        {
            try
            {
                var json = File.ReadAllText(tableSizesPath);
                var factors = JsonSerializer.Deserialize(json, KqlGuardSarifContext.Default.DictionaryStringInt32)
                    ?? new Dictionary<string, int>();
                enricher = new TableSizeEnricher(factors);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to read --table-sizes '{tableSizesPath}': {ex.Message}");
                return 2;
            }
        }
        Kusto.Language.GlobalState? schema = null;
        if (schemaPath != null)
        {
            try { schema = SchemaLoader.FromJson(File.ReadAllText(schemaPath)); }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to read --schema '{schemaPath}': {ex.Message}");
                return 2;
            }
        }
        var violations = new List<Violation>();
        var scores = new List<(string File, int Score)>();
        bool budgetBreached = false;
        foreach (var filePath in files)
        {
            var fileViolations = AnalyzeFile(filePath, schema);
            violations.AddRange(fileViolations);

            int score = 0;
            foreach (var v in fileViolations)
            {
                if (v.CostWeight > 0)
                {
                    score += enricher.Adjust(v.RuleId, v.CostWeight, v.Table);
                }
            }
            scores.Add((filePath, score));
            if (maxCost.HasValue && score > maxCost.Value)
            {
                budgetBreached = true;
            }
        }

        // Baseline: a finding's signature is rule+file+message (line-agnostic, so
        // edits above it don't churn the baseline). --write-baseline records all
        // current findings and passes; --baseline drops known ones, failing only on new.
        if (writeBaseline)
        {
            File.WriteAllLines(baselinePath ?? ".kql-guard-baseline",
                violations.Select(BaselineSig).Distinct().OrderBy(s => s, StringComparer.Ordinal));
            Console.Error.WriteLine($"Baseline written: {violations.Count} findings.");
            return 0;
        }
        if (baselinePath != null && File.Exists(baselinePath))
        {
            var known = new HashSet<string>(File.ReadAllLines(baselinePath));
            violations = violations.Where(v => !known.Contains(BaselineSig(v))).ToList();
        }

        // Output results.
        if (format == "sarif")
        {
            WriteSarif(violations, scores);
        }
        else if (format == "json")
        {
            WriteJson(violations, scores);
        }
        else
        {
            foreach (var v in violations)
            {
                Console.WriteLine($"{v.File}({v.Line},{v.Column}): {v.Severity} {v.RuleId}: {v.Message}");
            }
            foreach (var (file, score) in scores)
            {
                Console.WriteLine($"{file}: cost score {score}");
            }
            if (budgetBreached)
            {
                Console.Error.WriteLine($"Budget exceeded: a file's cost score is above --max-cost {maxCost}.");
            }
        }

        // Exit code: cost warnings are advisory (exit 0 on their own). The build
        // fails only on a real error (syntax KQL001 / schema KQL101), a --max-cost
        // budget breach, or --strict (which gates on any finding). A clean, valid
        // query stays 0 even if it carries cost.
        bool hasError = violations.Any(v => v.Severity == "error");
        bool failed = hasError || budgetBreached || (strict && violations.Count > 0);
        return failed ? 1 : 0;
    }

    /// <summary>
    /// Resolves a path argument to a sorted list of .kql files. Returns false
    /// (and prints an error) on a missing path. An empty directory yields an
    /// empty list with a true result — nothing to do is not a usage error.
    /// </summary>
    public static bool TryResolveFiles(string target, out string[] files)
    {
        if (File.Exists(target))
        {
            files = new[] { target };
            return true;
        }
        if (Directory.Exists(target))
        {
            files = Directory.GetFiles(target, "*.kql", SearchOption.AllDirectories)
                .Concat(Directory.GetFiles(target, "*.yaml", SearchOption.AllDirectories))
                .Concat(Directory.GetFiles(target, "*.yml", SearchOption.AllDirectories))
                .ToArray();
            Array.Sort(files, StringComparer.Ordinal);
            return true;
        }
        Console.Error.WriteLine($"Path not found: {target}");
        files = Array.Empty<string>();
        return false;
    }

    private static string BaselineSig(Violation v) => $"{v.RuleId}\t{v.File}\t{v.Message}";

    private static List<Violation> AnalyzeFile(string filePath, Kusto.Language.GlobalState? schema = null)
    {
        var violations = new List<Violation>();
        var raw = File.ReadAllText(filePath);
        var (text, lineOffset) = QueryExtraction.Extract(filePath, raw);
        if (text.Length == 0) return violations;   // yaml with no query block
        var code = KustoCode.Parse(text);

        // Rule KQL001: syntax validation — built-in diagnostics from the parser.
        var diagnostics = code.Syntax.GetContainedDiagnostics(DiagnosticsInclude.Syntactic);
        foreach (var diag in diagnostics)
        {
            GetLineAndColumn(code, diag.Start, out var line, out var col);
            violations.Add(new Violation(filePath, line, col, "error", "KQL001", diag.Message));
        }

        // Rule KQL101: opt-in semantic check against a supplied schema. Catches
        // unknown columns/tables — kql-guard is otherwise schema-blind.
        if (schema != null && violations.Count == 0)
        {
            var analyzed = KustoCode.ParseAndAnalyze(text, schema);
            foreach (var diag in analyzed.GetDiagnostics())
            {
                GetLineAndColumn(analyzed, diag.Start, out var line, out var col);
                violations.Add(new Violation(filePath, line, col, "error", "KQL101", diag.Message));
            }
        }

        // Rules KQL002–KQL008: static FinOps cost profiling. The Kusto parser is
        // error-tolerant, so we analyze the best-effort AST even alongside syntax
        // errors — the same query that won't compile is still worth costing.
        violations.AddRange(CostAnalyzer.Analyze(code, filePath));

        if (lineOffset > 0)
            violations = violations.Select(v => v with { Line = v.Line + lineOffset }).ToList();

        return Suppressions.Filter(violations, raw);
    }

    private static void WriteSarif(List<Violation> violations, List<(string File, int Score)> scores)
    {
        var rules = new List<SarifReportingDescriptor>();
        foreach (var r in Rules.All)
        {
            rules.Add(new SarifReportingDescriptor(
                r.Id,
                Name: r.Name,
                ShortDescription: new(r.ShortDescription),
                DefaultConfiguration: new(r.DefaultLevel)));
        }

        var results = new List<SarifResult>();
        foreach (var v in violations)
        {
            // GitHub Code Scanning requires workspace-relative URIs.
            // In CI the working directory is the repo root, so this produces
            // paths like "samples/query.kql" that map directly to the repo tree.
            var relPath = Path.GetRelativePath(Environment.CurrentDirectory, Path.GetFullPath(v.File));
            var artifactUri = relPath.Replace('\\', '/');

            results.Add(new SarifResult(
                RuleId: v.RuleId,
                RuleIndex: Rules.IndexOf(v.RuleId),
                Level: v.Severity,
                Message: new SarifMessage(v.Message),
                Locations: new List<SarifLocation>
                {
                    new(new SarifPhysicalLocation(
                        ArtifactLocation: new SarifArtifactLocation(artifactUri),
                        Region: new SarifRegion(v.Line, v.Column)))
                }));
        }

        // Carry per-file cost scores as a free-form run property (schema-valid).
        var costScores = new Dictionary<string, int>();
        foreach (var (file, score) in scores)
        {
            var relPath = Path.GetRelativePath(Environment.CurrentDirectory, Path.GetFullPath(file));
            costScores[relPath.Replace('\\', '/')] = score;
        }

        var log = new SarifLog(
            Schema: "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json",
            Version: "2.1.0",
            Runs: new List<SarifRun>
            {
                new(
                    Tool: new SarifTool(
                        Driver: new SarifToolComponent(
                            Name: "kql-guard",
                            SemanticVersion: "0.2.0",
                            InformationUri: "https://github.com/microsoft/kql-guard",
                            Rules: rules)),
                    Results: results,
                    ColumnKind: "unicodeCodePoints",
                    Properties: new SarifRunProperties(costScores))
            });

        Console.WriteLine(JsonSerializer.Serialize(log, KqlGuardSarifContext.Default.SarifLog));
    }

    private static void WriteJson(List<Violation> violations, List<(string File, int Score)> scores)
    {
        var findings = new List<JsonFinding>();
        foreach (var v in violations)
        {
            findings.Add(new JsonFinding(v.File, v.Line, v.Column, v.Severity, v.RuleId, v.Message, v.CostWeight));
        }
        var costScores = new Dictionary<string, int>();
        foreach (var (file, score) in scores) costScores[file] = score;
        var report = new JsonReport(findings, costScores);
        Console.WriteLine(JsonSerializer.Serialize(report, KqlGuardSarifContext.Default.JsonReport));
    }

    internal static void GetLineAndColumn(KustoCode code, int position, out int line, out int column)
    {
        if (!code.TryGetLineAndOffset(position, out line, out column))
        {
            line = 1;
            column = 1;
        }
    }
}

public readonly record struct Violation(
    string File,
    int Line,
    int Column,
    string Severity,
    string RuleId,
    string Message,
    int CostWeight = 0,
    string? Table = null);
