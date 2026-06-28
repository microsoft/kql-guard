using System;
using System.Collections.Generic;
using System.IO;
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
            Console.Error.WriteLine("Usage: kql-guard <path> [--format sarif] [--max-cost <int>]");
            Console.Error.WriteLine("  <path>          A .kql file or a directory to scan recursively.");
            Console.Error.WriteLine("  --format sarif  Emit SARIF v2.1.0 instead of text diagnostics.");
            Console.Error.WriteLine("  --max-cost <n>  Fail (exit 1) if any file's cost score exceeds n.");
            return args.Length < 1 ? 2 : 0;
        }

        var target = args[0];
        bool useSarif = false;
        int? maxCost = null;

        // Parse the remaining flags order-independently.
        for (int i = 1; i < args.Length; i++)
        {
            if (string.Equals(args[i], "--format", StringComparison.OrdinalIgnoreCase)
                && i + 1 < args.Length
                && string.Equals(args[i + 1], "sarif", StringComparison.OrdinalIgnoreCase))
            {
                useSarif = true;
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
            else
            {
                Console.Error.WriteLine($"Unrecognized argument: {args[i]}");
                return 2;
            }
        }

        // Resolve the list of .kql files from the positional argument.
        string[] files;
        if (File.Exists(target))
        {
            files = new[] { target };
        }
        else if (Directory.Exists(target))
        {
            files = Directory.GetFiles(target, "*.kql", SearchOption.AllDirectories);
            Array.Sort(files, StringComparer.Ordinal);
            if (files.Length == 0)
            {
                Console.Error.WriteLine($"No .kql files found under: {target}");
                return 0;
            }
        }
        else
        {
            Console.Error.WriteLine($"Path not found: {target}");
            return 2;
        }

        // Analyze every file, aggregate violations, and compute per-file cost scores.
        var enricher = new NullCostEnricher();
        var violations = new List<Violation>();
        var scores = new List<(string File, int Score)>();
        bool budgetBreached = false;
        foreach (var filePath in files)
        {
            var fileViolations = AnalyzeFile(filePath);
            violations.AddRange(fileViolations);

            int score = 0;
            foreach (var v in fileViolations)
            {
                if (v.CostWeight > 0)
                {
                    score += enricher.Adjust(v.RuleId, v.CostWeight, null);
                }
            }
            scores.Add((filePath, score));
            if (maxCost.HasValue && score > maxCost.Value)
            {
                budgetBreached = true;
            }
        }

        // Output results.
        if (useSarif)
        {
            WriteSarif(violations, scores);
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

        return (violations.Count > 0 || budgetBreached) ? 1 : 0;
    }

    private static List<Violation> AnalyzeFile(string filePath)
    {
        var violations = new List<Violation>();
        var text = File.ReadAllText(filePath);
        var code = KustoCode.Parse(text);

        // Rule KQL001: syntax validation — built-in diagnostics from the parser.
        var diagnostics = code.Syntax.GetContainedDiagnostics(DiagnosticsInclude.Syntactic);
        foreach (var diag in diagnostics)
        {
            GetLineAndColumn(code, diag.Start, out var line, out var col);
            violations.Add(new Violation(filePath, line, col, "error", "KQL001", diag.Message));
        }

        // Rules KQL002–KQL008: static FinOps cost profiling. The Kusto parser is
        // error-tolerant, so we analyze the best-effort AST even alongside syntax
        // errors — the same query that won't compile is still worth costing.
        violations.AddRange(CostAnalyzer.Analyze(code, filePath));

        return violations;
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
    int CostWeight = 0);
