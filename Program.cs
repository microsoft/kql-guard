using System;
using System.Collections.Generic;
using System.IO;
using Kusto.Language;
using Kusto.Language.Syntax;

namespace KqlGuard;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("Usage: kql-guard <file.kql>");
            return 2;
        }

        var filePath = args[0];
        if (!File.Exists(filePath))
        {
            Console.Error.WriteLine($"File not found: {filePath}");
            return 2;
        }

        var text = File.ReadAllText(filePath);
        var code = KustoCode.Parse(text);

        var violations = new List<Violation>();

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

        foreach (var v in violations)
        {
            Console.WriteLine($"{v.File}({v.Line},{v.Column}): {v.Severity} {v.RuleId}: {v.Message}");
        }

        return violations.Count > 0 ? 1 : 0;
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
