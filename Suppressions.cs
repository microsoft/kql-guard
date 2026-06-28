using System;
using System.Collections.Generic;

namespace KqlGuard;

/// <summary>
/// Inline suppression comments, mirroring eslint-disable / nolint conventions:
///   // kql-guard:disable           — same line, all rules
///   // kql-guard:disable KQL007    — same line, that rule
///   // kql-guard:disable-next-line KQL003,KQL008 — next line, listed rules
///   // kql-guard:disable-file      — whole file, all rules
/// Line-based by design (comments live in token trivia; scanning the text is
/// the lazy, robust route — no AST walking needed).
/// </summary>
public static class Suppressions
{
    private const string Prefix = "// kql-guard:";

    public static List<Violation> Filter(List<Violation> violations, string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n');
        bool fileWide = false;
        var fileRules = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // 1-based line -> rules suppressed there (empty set = all rules).
        var sameLine = new Dictionary<int, HashSet<string>>();
        var nextLine = new Dictionary<int, HashSet<string>>();

        for (int i = 0; i < lines.Length; i++)
        {
            var idx = lines[i].IndexOf(Prefix, StringComparison.OrdinalIgnoreCase);
            if (idx < 0) continue;
            var directive = lines[i][(idx + Prefix.Length)..].Trim();
            var (verb, rules) = SplitVerb(directive);
            switch (verb)
            {
                case "disable-file": fileWide = fileWide || rules.Count == 0; fileRules.UnionWith(rules); break;
                case "disable": sameLine[i + 1] = rules; break;
                case "disable-next-line": nextLine[i + 2] = rules; break;
            }
        }

        var kept = new List<Violation>(violations.Count);
        foreach (var v in violations)
        {
            if (fileWide || fileRules.Contains(v.RuleId)) continue;
            if (Suppressed(sameLine, v.Line, v.RuleId)) continue;
            if (Suppressed(nextLine, v.Line, v.RuleId)) continue;
            kept.Add(v);
        }
        return kept;
    }

    private static bool Suppressed(Dictionary<int, HashSet<string>> map, int line, string ruleId) =>
        map.TryGetValue(line, out var rules) && (rules.Count == 0 || rules.Contains(ruleId));

    private static (string verb, HashSet<string> rules) SplitVerb(string directive)
    {
        var space = directive.IndexOf(' ');
        var verb = space < 0 ? directive : directive[..space];
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (space >= 0)
        {
            foreach (var r in directive[(space + 1)..].Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                set.Add(r);
            }
        }
        return (verb, set);
    }
}
