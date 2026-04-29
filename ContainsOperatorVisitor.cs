using System.Collections.Generic;
using Kusto.Language;
using Kusto.Language.Syntax;

namespace KqlGuard;

/// <summary>
/// Walks the AST looking for 'contains' / 'contains_cs' operators
/// and suggests the more performant 'has' / 'has_cs' alternatives.
/// </summary>
public sealed class ContainsOperatorVisitor : DefaultSyntaxVisitor
{
    private readonly KustoCode _code;
    private readonly string _filePath;
    private readonly List<Violation> _violations = new();

    public IReadOnlyList<Violation> Violations => _violations;

    public ContainsOperatorVisitor(KustoCode code, string filePath)
    {
        _code = code;
        _filePath = filePath;
    }

    protected override void DefaultVisit(SyntaxNode node)
    {
        for (int i = 0; i < node.ChildCount; i++)
        {
            if (node.GetChild(i) is SyntaxNode child)
            {
                child.Accept(this);
            }
        }
    }

    public override void VisitBinaryExpression(BinaryExpression node)
    {
        if (node.Kind == SyntaxKind.ContainsExpression ||
            node.Kind == SyntaxKind.ContainsCsExpression)
        {
            Program.GetLineAndColumn(_code, node.Operator.TextStart, out var line, out var col);

            var suggested = node.Kind == SyntaxKind.ContainsCsExpression ? "has_cs" : "has";
            _violations.Add(new Violation(
                _filePath,
                line,
                col,
                "warning",
                "KQL002",
                $"Avoid '{node.Operator.Text}'; prefer '{suggested}' for whole-term matching (better performance)."));
        }

        // Continue walking children in case of nested expressions.
        DefaultVisit(node);
    }
}
