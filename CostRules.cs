using System;
using System.Collections.Generic;
using System.Linq;
using Kusto.Language;
using Kusto.Language.Syntax;

namespace KqlGuard;

/// <summary>
/// Central registry of every diagnostic rule: id, SARIF metadata, default
/// severity, and FinOps cost weight. This single table is the calibration
/// knob — tune a heuristic's noise by changing one number here, nowhere else.
/// </summary>
public sealed record RuleInfo(
    string Id,
    string Name,
    string ShortDescription,
    string DefaultLevel,
    int CostWeight);

public static class Rules
{
    // ponytail: weights are relative and unitless on purpose. No dollar figures
    // are possible offline; a fabricated "$" would mislead. Live-table sizing,
    // if ever needed, arrives via ICostEnricher — not by faking a number here.
    public static readonly IReadOnlyList<RuleInfo> All = new List<RuleInfo>
    {
        new("KQL001", "SyntaxError",
            "KQL syntax error detected by the parser.", "error", 0),
        new("KQL101", "UnknownColumnOrTable",
            "Reference to a column, table, or function not present in the supplied schema (requires --schema).", "error", 0),
        new("KQL002", "AvoidContainsOperator",
            "The 'contains' operator performs a full-text scan; prefer 'has' for whole-term matching.", "warning", 1),
        new("KQL003", "MissingTimeFilter",
            "Table query has no time-range filter (ago()/between); it scans the full table — a top cost driver.", "warning", 5),
        new("KQL004", "UnscopedSearch",
            "'search' with no table scope queries every table; scope it with 'search in (Table)' or use a table reference.", "warning", 5),
        new("KQL005", "WildcardUnion",
            "'union' over a wildcard table set fans out across many tables; list the tables explicitly.", "warning", 4),
        new("KQL006", "UnwindowedJoin",
            "'join' with no time-range filter materializes full tables; add a time window before joining.", "warning", 3),
        new("KQL007", "RegexHeavyOperation",
            "Regex operations (matches regex / extract / parse kind=regex) are CPU-heavy; prefer 'has'/parse simple where possible.", "warning", 2),
        new("KQL008", "NoColumnOrRowReduction",
            "Query returns table rows with no project/summarize/take; it keeps every column and row in memory.", "warning", 1),
        new("KQL009", "UnboundedMvExpand",
            "'mv-expand' with no 'limit' can explode row counts; add 'limit N' to cap fan-out.", "warning", 3),
        new("KQL010", "CrossClusterQuery",
            "Cross-cluster/database reference (cluster()/database()) adds network egress and latency cost; keep queries cluster-local where possible.", "warning", 2),
        new("KQL011", "UnboundedSort",
            "'sort'/'order by' with no following 'take'/'top' materializes and sorts the whole result; cap it with 'take N' or use 'top N'.", "warning", 1),
        new("KQL012", "CaseFoldEquality",
            "tolower()/toupper() around an equality defeats the index; use the case-insensitive '=~' operator instead.", "warning", 2),
        new("KQL013", "NonDeterministicTake",
            "'take'/'limit' without 'sort'/'top' returns arbitrary rows; add an order so results are reproducible.", "warning", 1),
        new("KQL014", "ManyComputedExtendColumns",
            "Flags Extend operators that create many computed columns in one step, which can be costly.", "warning", 2),
    };

    private static readonly Dictionary<string, int> Index =
        All.Select((r, i) => (r.Id, i)).ToDictionary(x => x.Id, x => x.i);

    public static int Weight(string ruleId) =>
        All.First(r => r.Id == ruleId).CostWeight;

    public static int IndexOf(string ruleId) => Index[ruleId];
}

/// <summary>
/// Seam for future live-API cost enrichment (e.g. real table sizes from ADX
/// or Log Analytics). The default is a no-op; this change performs NO network
/// call, auth, or DB connection. A later change supplies a real implementation
/// without touching the scoring pipeline.
/// </summary>
public interface ICostEnricher
{
    int Adjust(string ruleId, int staticWeight, string? tableName);
}

public sealed class NullCostEnricher : ICostEnricher
{
    public int Adjust(string ruleId, int staticWeight, string? tableName) => staticWeight;
}

/// <summary>
/// Offline enrichment: scales scan-related weights (KQL003/KQL008) by a per-table
/// multiplier loaded from a JSON map {"TableName": factor}. A full-table scan on a
/// 100x table costs ~100x more, so a config file is enough to sharpen the score
/// without any network call. This is the lazy stand-in for live table sizing —
/// the live API enricher would implement the same interface, no pipeline change.
/// ponytail: file-based factors; swap for a live ADX/.show table details lookup
/// behind this same interface when real numbers matter.
/// </summary>
public sealed class TableSizeEnricher : ICostEnricher
{
    private readonly Dictionary<string, int> _factors;

    public TableSizeEnricher(Dictionary<string, int> factors) => _factors = factors;

    public int Adjust(string ruleId, int staticWeight, string? tableName)
    {
        if (tableName != null && (ruleId == "KQL003" || ruleId == "KQL008")
            && _factors.TryGetValue(tableName, out var factor) && factor > 1)
        {
            return staticWeight * factor;
        }
        return staticWeight;
    }
}

/// <summary>
/// Static, offline FinOps cost profiler. Walks the parsed AST and flags
/// high-cost query shapes (KQL002–KQL008), each carrying a relative cost weight.
/// </summary>
public static class CostAnalyzer
{
    private static readonly HashSet<string> RegexFunctions =
        new(StringComparer.OrdinalIgnoreCase) { "extract", "extract_all" };

    // Operators that reduce columns or rows, so a query containing one is not
    // a "scan everything" query for KQL008 purposes.
    private static readonly HashSet<string> ReducerOperators = new(StringComparer.Ordinal)
    {
        "ProjectOperator", "ProjectAwayOperator", "ProjectKeepOperator",
        "ProjectRenameOperator", "ProjectReorderOperator",
        "SummarizeOperator", "TakeOperator", "DistinctOperator",
        "TopOperator", "TopNestedOperator", "TopHittersOperator",
        "CountOperator", "SampleOperator", "SampleDistinctOperator",
        "GetSchemaOperator", "FacetOperator",
    };

    public static List<Violation> Analyze(KustoCode code, string filePath)
    {
        var violations = new List<Violation>();
        var root = code.Syntax;

        // --- Node-local rules (KQL002, KQL004, KQL005, KQL006, KQL007) ---

        // KQL002: contains / contains_cs.
        foreach (var bin in root.GetDescendants<BinaryExpression>())
        {
            if (bin.Kind == SyntaxKind.ContainsExpression || bin.Kind == SyntaxKind.ContainsCsExpression)
            {
                var suggested = bin.Kind == SyntaxKind.ContainsCsExpression ? "has_cs" : "has";
                violations.Add(Make(code, filePath, bin.Operator.TextStart, "KQL002",
                    $"Avoid '{bin.Operator.Text}'; prefer '{suggested}' for whole-term matching (better performance)."));
            }
        }

        // KQL004: search with no table scope.
        foreach (var search in root.GetDescendants<SearchOperator>())
        {
            if (search.InClause == null)
            {
                violations.Add(Make(code, filePath, search.SearchKeyword.TextStart, "KQL004",
                    "Unscoped 'search' queries every table; scope it with 'search in (Table1, Table2) ...' or filter a specific table."));
            }
        }

        // KQL005: union over a wildcard table set.
        foreach (var union in root.GetDescendants<UnionOperator>())
        {
            if (union.GetDescendants<WildcardedName>().Count > 0)
            {
                violations.Add(Make(code, filePath, union.TextStart, "KQL005",
                    "Wildcard 'union' fans out across many tables; list the specific tables instead."));
            }
        }

        // KQL007: regex-heavy operations.
        foreach (var bin in root.GetDescendants<BinaryExpression>())
        {
            if (bin.Kind == SyntaxKind.MatchesRegexExpression)
            {
                violations.Add(Make(code, filePath, bin.Operator.TextStart, "KQL007",
                    "'matches regex' is CPU-heavy; prefer 'has'/'startswith' when matching whole terms."));
            }
        }
        foreach (var call in root.GetDescendants<FunctionCallExpression>())
        {
            if (RegexFunctions.Contains(call.Name.SimpleName))
            {
                violations.Add(Make(code, filePath, call.TextStart, "KQL007",
                    $"'{call.Name.SimpleName}' uses regex and is CPU-heavy; prefer 'parse'/'split' for simple extraction."));
            }
        }
        foreach (var parse in root.GetDescendants<ParseOperator>())
        {
            // ponytail: text-scan for kind=regex (default 'parse' is simple mode,
            // which is cheap). Upgrade to NamedParameter inspection if it ever misfires.
            if (parse.ToString().Replace(" ", "").Contains("kind=regex", StringComparison.OrdinalIgnoreCase))
            {
                violations.Add(Make(code, filePath, parse.TextStart, "KQL007",
                    "'parse kind=regex' is CPU-heavy; use simple 'parse' mode when the input is delimited."));
            }
        }

        // KQL009: mv-expand without a row limit.
        foreach (var mv in root.GetDescendants<MvExpandOperator>())
        {
            // ponytail: text-scan for 'limit' — covers both 'mv-expand limit N' and a
            // following '| limit'. Upgrade to RowLimitClause inspection if noisy.
            if (!mv.ToString().Contains("limit", StringComparison.OrdinalIgnoreCase))
            {
                violations.Add(Make(code, filePath, mv.TextStart, "KQL009",
                    "Unbounded 'mv-expand'; add 'limit N' to cap row explosion."));
            }
        }

        // KQL010: cross-cluster/database references.
        foreach (var call in root.GetDescendants<FunctionCallExpression>())
        {
            var fn = call.Name.SimpleName;
            if (fn.Equals("cluster", StringComparison.OrdinalIgnoreCase)
                || fn.Equals("database", StringComparison.OrdinalIgnoreCase))
            {
                violations.Add(Make(code, filePath, call.TextStart, "KQL010",
                    $"'{fn}()' references another cluster/database; network egress adds latency and cost."));
            }
        }

        // KQL011: sort with no take/top — full result materialized and sorted.
        foreach (var sort in root.GetDescendants<SortOperator>())
        {
            if (root.GetDescendants<TakeOperator>().Count == 0)
            {
                violations.Add(Make(code, filePath, sort.TextStart, "KQL011",
                    "Unbounded 'sort'; add 'take N' or use 'top N by ...' to avoid sorting the full result."));
            }
        }

        // KQL012: tolower()/toupper() around an equality — defeats the index.
        foreach (var eq in root.GetDescendants<BinaryExpression>())
        {
            if (eq.Kind != SyntaxKind.EqualExpression && eq.Kind != SyntaxKind.NotEqualExpression) continue;
            foreach (var call in eq.GetDescendants<FunctionCallExpression>())
            {
                var fn = call.Name.SimpleName;
                if (fn.Equals("tolower", StringComparison.OrdinalIgnoreCase) || fn.Equals("toupper", StringComparison.OrdinalIgnoreCase))
                {
                    violations.Add(Make(code, filePath, eq.TextStart, "KQL012",
                        $"'{fn}()' before '==' defeats the index; use case-insensitive '=~' instead."));
                    break;
                }
            }
        }

        // KQL013: take/limit with no ordering — arbitrary, non-reproducible rows.
        if (root.GetDescendants<SortOperator>().Count == 0 && root.GetDescendants<TopOperator>().Count == 0)
        {
            foreach (var take in root.GetDescendants<TakeOperator>())
            {
                violations.Add(Make(code, filePath, take.TextStart, "KQL013",
                    "'take'/'limit' without 'sort'/'top' returns arbitrary rows; add an order to make results reproducible."));
            }
        }

        // --- Statement-level heuristics (KQL003, KQL006, KQL008) ---
        foreach (var stmt in root.GetDescendants<ExpressionStatement>())
        {
            var expr = stmt.Expression;
            var source = BaseSource(expr);

            // ponytail: heuristic — time bound = any ago() call or BETWEEN. A literal
            // datetime comparison (TimeGenerated > datetime(...)) is not detected; tune
            // via the KQL003 weight in Rules if it proves noisy.
            bool hasTimeBound =
                expr.GetDescendants<FunctionCallExpression>()
                    .Any(c => c.Name.SimpleName.Equals("ago", StringComparison.OrdinalIgnoreCase))
                || expr.GetDescendants<BetweenExpression>().Count > 0;

            // Only treat queries that read directly from a named table as candidates
            // for KQL003/KQL008. search/union/print have their own rules / are not
            // table scans.
            bool readsTable = source is NameReference;
            string? tableName = (source as NameReference)?.SimpleName;

            if (readsTable && !hasTimeBound)
            {
                violations.Add(Make(code, filePath, source.TextStart, "KQL003",
                    "No time filter; add e.g. '| where TimeGenerated > ago(1d)' to avoid a full-table scan.", tableName));
            }

            // KQL006: a join with no time window anywhere in the statement.
            // ponytail: per-statement check — if the statement has a time bound we
            // assume the join is windowed. Misses joins where only one side is
            // windowed; revisit if false negatives matter.
            if (!hasTimeBound)
            {
                foreach (var join in expr.GetDescendants<JoinOperator>())
                {
                    violations.Add(Make(code, filePath, join.TextStart, "KQL006",
                        "Join has no time window; add a time filter (e.g. 'where TimeGenerated > ago(1d)') before joining."));
                }
            }

            if (readsTable)
            {
                bool hasReducer = expr.GetDescendants<SyntaxNode>()
                    .Any(n => ReducerOperators.Contains(n.GetType().Name));
                if (!hasReducer)
                {
                    violations.Add(Make(code, filePath, source.TextStart, "KQL008",
                        "No project/summarize/take; reduce columns and rows early to cut memory and cost.", tableName));
                }
            }
        }

        foreach (var x in root.GetDescendants<ExtendOperator>()) { if (x.GetDescendants<SimpleNamedExpression>().Count >= 6) { violations.Add(Make(code, filePath, x.TextStart, "KQL014", "'extend' defining many computed columns (>=6) can be expensive; consider breaking up work, materializing intermediate results, or projecting only the fields you need.")); } }
        return violations;
    }

    private static Expression BaseSource(Expression expr)
    {
        while (expr is PipeExpression pipe)
        {
            expr = pipe.Expression;
        }
        return expr;
    }

    private static Violation Make(KustoCode code, string filePath, int position, string ruleId, string message, string? table = null)
    {
        Program.GetLineAndColumn(code, position, out var line, out var col);
        var info = Rules.All.First(r => r.Id == ruleId);
        return new Violation(filePath, line, col, info.DefaultLevel, ruleId, message, info.CostWeight, table);
    }
}
