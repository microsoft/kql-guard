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
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: kql-guard <path> [--format sarif]");
            Console.Error.WriteLine("  <path>  A .kql file or a directory to scan recursively.");
            return 2;
        }

        var target = args[0];
        var useSarif = args.Length >= 3
            && string.Equals(args[1], "--format", StringComparison.OrdinalIgnoreCase)
            && string.Equals(args[2], "sarif", StringComparison.OrdinalIgnoreCase);

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

        // Analyze every file and aggregate violations.
        var violations = new List<Violation>();
        foreach (var filePath in files)
        {
            violations.AddRange(AnalyzeFile(filePath));
        }

        // Output results.
        if (useSarif)
        {
            WriteSarif(violations);
        }
        else
        {
            foreach (var v in violations)
            {
                Console.WriteLine($"{v.File}({v.Line},{v.Column}): {v.Severity} {v.RuleId}: {v.Message}");
            }
        }

        return violations.Count > 0 ? 1 : 0;
    }

    private static List<Violation> AnalyzeFile(string filePath)
    {
        var violations = new List<Violation>();
        var text = File.ReadAllText(filePath);
        var code = KustoCode.Parse(text);

        // Rule 1: Syntax validation — built-in diagnostics from the parser.
        var diagnostics = code.Syntax.GetContainedDiagnostics(DiagnosticsInclude.Syntactic);
        foreach (var diag in diagnostics)
        {
            GetLineAndColumn(code, diag.Start, out var line, out var col);
            violations.Add(new Violation(filePath, line, col, "error", "KQL001", diag.Message));
        }

        // Rule 2: Performance anti-pattern — 'contains' operator usage.
        var visitor = new ContainsOperatorVisitor(code, filePath);
        code.Syntax.Accept(visitor);
        violations.AddRange(visitor.Violations);

        return violations;
    }

    private static void WriteSarif(List<Violation> violations)
    {
        var rules = new List<SarifReportingDescriptor>
        {
            new("KQL001",
                Name: "SyntaxError",
                ShortDescription: new("KQL syntax error detected by the parser."),
                DefaultConfiguration: new("error")),
            new("KQL002",
                Name: "AvoidContainsOperator",
                ShortDescription: new("The 'contains' operator performs a full-text scan; prefer 'has' for whole-term matching."),
                DefaultConfiguration: new("warning")),
        };

        var results = new List<SarifResult>();
        foreach (var v in violations)
        {
            // GitHub Code Scanning requires workspace-relative URIs.
            // In CI the working directory is the repo root, so this produces
            // paths like "samples/query.kql" that map directly to the repo tree.
            var relPath = Path.GetRelativePath(Environment.CurrentDirectory, Path.GetFullPath(v.File));
            var artifactUri = relPath.Replace('\\', '/');

            var ruleIndex = v.RuleId == "KQL001" ? 0 : 1;
            results.Add(new SarifResult(
                RuleId: v.RuleId,
                RuleIndex: ruleIndex,
                Level: v.Severity,
                Message: new SarifMessage(v.Message),
                Locations: new List<SarifLocation>
                {
                    new(new SarifPhysicalLocation(
                        ArtifactLocation: new SarifArtifactLocation(artifactUri),
                        Region: new SarifRegion(v.Line, v.Column)))
                }));
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
                            SemanticVersion: "0.1.0",
                            InformationUri: "https://github.com/microsoft/kql-guard",
                            Rules: rules)),
                    Results: results,
                    ColumnKind: "unicodeCodePoints")
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
    string Message);
