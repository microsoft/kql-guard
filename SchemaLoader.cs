using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Kusto.Language;
using Kusto.Language.Symbols;

namespace KqlGuard;

/// <summary>A column in a supplied table schema: matches okayql's indexer JSON.</summary>
public sealed record SchemaColumn(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("type")] string Type);

/// <summary>
/// Builds a Kusto GlobalState from a JSON schema map so queries can be
/// semantically analyzed offline. JSON shape: {"Table":[{"name","type"}]}.
/// </summary>
public static class SchemaLoader
{
    public static GlobalState FromJson(string json)
    {
        var map = JsonSerializer.Deserialize(json, KqlGuardSarifContext.Default.DictionaryStringListSchemaColumn)
            ?? new Dictionary<string, List<SchemaColumn>>();
        var tables = new List<TableSymbol>();
        foreach (var (table, cols) in map)
        {
            var schema = string.Join(", ", cols.Select(c => $"{c.Name}: {Map(c.Type)}"));
            tables.Add(new TableSymbol(table, $"({schema})"));
        }
        return GlobalState.Default.WithDatabase(new DatabaseSymbol("db", tables));
    }

    // ponytail: pass the type through; Kusto treats unknowns as dynamic. Map the
    // few names that differ from CSL keywords, widen the list only if a real
    // schema trips it.
    private static string Map(string t) => t.ToLowerInvariant() switch
    {
        "system.datetime" => "datetime",
        "system.string" => "string",
        "system.int32" or "int" => "int",
        "system.int64" => "long",
        "" => "dynamic",
        _ => t
    };
}
