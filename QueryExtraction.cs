using System;
using System.Collections.Generic;
using System.Linq;

namespace KqlGuard;

/// <summary>
/// Pulls the KQL out of a file. A .kql file is its own query. A Sentinel
/// detection rule (.yaml/.yml) embeds the query under a 'query:' block scalar;
/// we lift it and remember the line offset so diagnostics point at the real row.
/// </summary>
public static class QueryExtraction
{
    // ponytail: line-scan for 'query: |' / 'query: >' block scalars, the shape
    // every Sentinel detection rule uses. Skips inline/quoted one-liners and
    // multiple queries per file — add a YAML parser only if those show up.
    public static (string Kql, int LineOffset) Extract(string path, string text)
    {
        if (!path.EndsWith(".yaml", StringComparison.OrdinalIgnoreCase)
            && !path.EndsWith(".yml", StringComparison.OrdinalIgnoreCase))
            return (text, 0);

        var lines = text.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var t = lines[i].TrimStart();
            if (!(t.StartsWith("query:") && t.TrimEnd().EndsWith("|") || t.StartsWith("query:") && t.TrimEnd().EndsWith(">")))
                continue;

            int indent = lines[i].Length - t.Length;
            var body = new List<string>();
            int j = i + 1;
            for (; j < lines.Length; j++)
            {
                if (lines[j].Trim().Length == 0) { body.Add(""); continue; }
                int li = lines[j].Length - lines[j].TrimStart().Length;
                if (li <= indent) break;
                body.Add(lines[j]);
            }
            int strip = body.Where(b => b.Length > 0).Select(b => b.Length - b.TrimStart().Length).DefaultIfEmpty(0).Min();
            return (string.Join("\n", body.Select(b => b.Length >= strip ? b[strip..] : b)), i + 1);
        }
        return ("", 0); // no query block: nothing to lint
    }
}
