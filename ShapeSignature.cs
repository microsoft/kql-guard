using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Kusto.Language;
using Kusto.Language.Syntax;

namespace KqlGuard;

/// <summary>
/// Emits a boundary-safe structural signature for a KQL query: a pre-order walk
/// of the parsed syntax tree recording each node's SyntaxKind and, for built-in
/// function calls, the built-in name. User identifiers, literals, and
/// user-defined function names are never emitted (only their node KINDS), so the
/// signature carries structure without any confidential query text. It feeds the
/// confidential Kuskus mining pipeline (kql-guard --format json --shapes) and is
/// inert for public lint-in-CI users, who simply never pass the flag.
/// </summary>
public static class ShapeSignature
{
    // Built-in scalar functions + aggregates are the public KQL language surface,
    // so emitting their names leaks nothing. Any call whose name is NOT in this
    // set is user-defined and is masked to its node kind.
    private static readonly HashSet<string> Builtins = BuildBuiltins();

    private static HashSet<string> BuildBuiltins()
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var f in Kusto.Language.Functions.All) set.Add(f.Name);
        foreach (var a in Kusto.Language.Aggregates.All) set.Add(a.Name);
        return set;
    }

    /// <summary>
    /// Returns the query's shape signature, or null when the file has no query
    /// (empty extraction) or fails to parse (any syntactic diagnostic) — such
    /// queries are omitted from the shapes map per the spec.
    /// </summary>
    public static string? Compute(string filePath)
    {
        var raw = File.ReadAllText(filePath);
        var (text, _) = QueryExtraction.Extract(filePath, raw);
        if (text.Length == 0) return null;
        var code = KustoCode.Parse(text);
        if (code.Syntax.GetContainedDiagnostics(DiagnosticsInclude.Syntactic).Count > 0)
            return null;
        var sb = new StringBuilder();
        Walk(code.Syntax, sb);
        return sb.ToString();
    }

    private static void Walk(SyntaxElement? node, StringBuilder sb)
    {
        if (node == null) return;
        if (node is SyntaxNode sn)
        {
            sb.Append(sn.Kind);
            if (sn is FunctionCallExpression fc && Builtins.Contains(fc.Name.SimpleName))
                sb.Append(':').Append(fc.Name.SimpleName);
            sb.Append(';');
        }
        for (int i = 0; i < node.ChildCount; i++)
            Walk(node.GetChild(i), sb);
    }
}
