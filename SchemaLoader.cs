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

/// <summary>A stored function: a CSL parameter list and body, bound so calls resolve.</summary>
public sealed record SchemaFunction(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("parameters")] string Parameters,
    [property: JsonPropertyName("body")] string Body);

/// <summary>Object-form schema file written by `pull`: named tables plus functions.</summary>
public sealed record SchemaFile(
    [property: JsonPropertyName("tables")] Dictionary<string, List<SchemaColumn>>? Tables,
    [property: JsonPropertyName("functions")] List<SchemaFunction>? Functions);

/// <summary>
/// Builds a Kusto GlobalState from a JSON schema file so queries can be
/// semantically analyzed offline. Accepts two forms: the legacy bare map
/// {"Table":[{"name","type"}]}, and the object form written by `pull`
/// {"tables":{...},"functions":[{"name","parameters","body"}]}.
/// </summary>
public static class SchemaLoader
{
    public static GlobalState FromJson(string json)
    {
        var (tableMap, functions) = Parse(json);

        var members = new List<Symbol>();
        foreach (var (table, cols) in tableMap)
        {
            var schema = string.Join(", ", cols.Select(c => $"{c.Name}: {MapType(c.Type)}"));
            members.Add(new TableSymbol(table, $"({schema})"));
        }
        foreach (var f in functions)
        {
            members.Add(new FunctionSymbol(f.Name, f.Parameters, f.Body));
        }
        return GlobalState.Default.WithDatabase(new DatabaseSymbol("db", members));
    }

    // The object form is distinguished by a "tables" property whose value is an
    // object (the legacy form's values are all arrays). ponytail: this one probe
    // is enough; widen only if a real table is ever literally named "tables".
    private static (Dictionary<string, List<SchemaColumn>>, List<SchemaFunction>) Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Object
            && root.TryGetProperty("tables", out var t)
            && t.ValueKind == JsonValueKind.Object)
        {
            var file = JsonSerializer.Deserialize(json, KqlGuardSarifContext.Default.SchemaFile);
            return (file?.Tables ?? new(), file?.Functions ?? new());
        }
        var map = JsonSerializer.Deserialize(json, KqlGuardSarifContext.Default.DictionaryStringListSchemaColumn)
            ?? new Dictionary<string, List<SchemaColumn>>();
        return (map, new List<SchemaFunction>());
    }

    // ponytail: pass the type through; Kusto treats unknowns as dynamic. Map the
    // common .NET type names (as returned by `.show database schema as json`) to
    // their CSL keywords; widen the list only if a real schema trips it.
    internal static string MapType(string t) => t.ToLowerInvariant() switch
    {
        "system.datetime" => "datetime",
        "system.string" => "string",
        "system.int32" or "int" => "int",
        "system.int64" => "long",
        "system.double" or "system.single" => "real",
        "system.boolean" => "bool",
        "system.guid" or "system.sqlguid" => "guid",
        "system.timespan" => "timespan",
        "system.data.sqltypes.sqldecimal" or "system.decimal" => "decimal",
        "system.object" => "dynamic",
        "" => "dynamic",
        _ => t
    };
}
