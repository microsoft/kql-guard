using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KqlGuard;

// --- Wire shapes -----------------------------------------------------------
// Kusto v1 REST envelope (POST <cluster>/v1/rest/mgmt): the result of a control
// command is Tables[0], a column list plus rows of heterogeneous cells.
public sealed record MgmtRequest(
    [property: JsonPropertyName("db")] string Db,
    [property: JsonPropertyName("csl")] string Csl);

public sealed record KustoV1Response(
    [property: JsonPropertyName("Tables")] List<KustoV1Table>? Tables);

public sealed record KustoV1Table(
    [property: JsonPropertyName("Columns")] List<KustoV1Column>? Columns,
    [property: JsonPropertyName("Rows")] List<List<JsonElement>>? Rows);

public sealed record KustoV1Column(
    [property: JsonPropertyName("ColumnName")] string? ColumnName);

// Inner JSON string returned by `.show database schema as json`. Column and
// parameter `Type` is a .NET type name (e.g. System.String); `CslType` (when
// present) is the KQL keyword.
public sealed record ShowSchemaRoot(
    [property: JsonPropertyName("Databases")] Dictionary<string, ShowSchemaDb>? Databases);

public sealed record ShowSchemaDb(
    [property: JsonPropertyName("Tables")] Dictionary<string, ShowSchemaTable>? Tables,
    [property: JsonPropertyName("Functions")] Dictionary<string, ShowSchemaFunction>? Functions);

public sealed record ShowSchemaTable(
    [property: JsonPropertyName("OrderedColumns")] List<ShowSchemaField>? OrderedColumns);

public sealed record ShowSchemaFunction(
    [property: JsonPropertyName("Name")] string? Name,
    [property: JsonPropertyName("InputParameters")] List<ShowSchemaField>? InputParameters,
    [property: JsonPropertyName("Body")] string? Body);

public sealed record ShowSchemaField(
    [property: JsonPropertyName("Name")] string? Name,
    [property: JsonPropertyName("Type")] string? Type,
    [property: JsonPropertyName("CslType")] string? CslType);

/// <summary>
/// `pull` subcommand: fetch a live cluster's schema (and optional table sizes)
/// over the Kusto REST API and write them into the same --schema / --table-sizes
/// files the offline linter already consumes. No SDK dependency, so the single
/// NativeAOT binary is preserved; auth is an injected bearer token only.
/// </summary>
public static class SchemaPull
{
    public static int Run(string[] args)
    {
        string? cluster = null, database = null, token = null, withSizes = null;
        string? fromResponse = null, sizesFromResponse = null;
        string outPath = "schemas.json";
        long? sizeBaseline = null;

        for (int i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--cluster": cluster = Next(args, ref i); break;
                case "--database" or "-d": database = Next(args, ref i); break;
                case "--out" or "-o": outPath = Next(args, ref i) ?? outPath; break;
                case "--token": token = Next(args, ref i); break;
                case "--with-sizes": withSizes = Next(args, ref i); break;
                case "--size-baseline":
                    var b = Next(args, ref i);
                    if (!long.TryParse(b, out var bl)) return Usage($"--size-baseline expects an integer, got '{b}'.");
                    sizeBaseline = bl;
                    break;
                // Offline seams: reuse a captured REST response instead of calling
                // the cluster. Handy for debugging real captures and for tests.
                case "--from-response": fromResponse = Next(args, ref i); break;
                case "--sizes-from-response": sizesFromResponse = Next(args, ref i); break;
                default: return Usage($"Unknown pull option '{args[i]}'.");
            }
        }

        token ??= Environment.GetEnvironmentVariable("KQL_GUARD_TOKEN");
        bool offline = fromResponse != null;

        if (database == null) return Usage("--database is required.");
        if (!offline)
        {
            if (cluster == null) return Usage("--cluster is required (or use --from-response for offline parsing).");
            if (string.IsNullOrEmpty(token)) return Usage("A bearer token is required: pass --token or set KQL_GUARD_TOKEN.");
        }

        try
        {
            var rawSchema = offline
                ? File.ReadAllText(fromResponse!)
                : FetchMgmt(cluster!, database, token!, SchemaCommand(database));
            var (tables, functions) = ParseSchema(ExtractCell(rawSchema), database);

            File.WriteAllText(outPath, JsonSerializer.Serialize(
                new SchemaFile(tables, functions), KqlGuardSarifContext.Default.SchemaFile));
            Console.Error.WriteLine($"wrote {outPath}: {tables.Count} tables, {functions.Count} functions");

            if (withSizes != null)
            {
                string rawSizes;
                if (sizesFromResponse != null) rawSizes = File.ReadAllText(sizesFromResponse);
                else if (offline) throw new InvalidOperationException(
                    "offline mode needs --sizes-from-response to compute --with-sizes.");
                else rawSizes = FetchMgmt(cluster!, database, token!, ".show tables details");

                var factors = ParseSizes(rawSizes, sizeBaseline);
                File.WriteAllText(withSizes, JsonSerializer.Serialize(
                    factors, KqlGuardSarifContext.Default.DictionaryStringInt32));
                Console.Error.WriteLine($"wrote {withSizes}: {factors.Count} table size factors");
            }
            return 0;
        }
        catch (Exception ex)
        {
            // Never echo the token; only the message.
            Console.Error.WriteLine($"pull failed: {ex.Message}");
            return 1;
        }
    }

    private static string? Next(string[] args, ref int i) => i + 1 < args.Length ? args[++i] : null;

    private static int Usage(string message)
    {
        Console.Error.WriteLine($"kql-guard pull: {message}");
        Console.Error.WriteLine("Usage: kql-guard pull --cluster <uri> --database <db> [-o schemas.json]");
        Console.Error.WriteLine("                      [--with-sizes sizes.json] [--size-baseline <bytes>] [--token <jwt>]");
        Console.Error.WriteLine("  Token: --token or KQL_GUARD_TOKEN (e.g. `az account get-access-token`). Never logged.");
        return 2;
    }

    // ponytail: names in commands use bracket-quoting; escape the two chars that
    // can break it. Real database names are plain identifiers in practice.
    private static string SchemaCommand(string db)
    {
        var esc = db.Replace("\\", "\\\\").Replace("\"", "\\\"");
        return $".show database [\"{esc}\"] schema as json";
    }

    private static string FetchMgmt(string cluster, string db, string token, string csl)
    {
        var url = cluster.TrimEnd('/') + "/v1/rest/mgmt";
        var body = JsonSerializer.Serialize(new MgmtRequest(db, csl), KqlGuardSarifContext.Default.MgmtRequest);

        using var http = new HttpClient();
        using var req = new HttpRequestMessage(HttpMethod.Post, url);
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");

        using var resp = http.Send(req);
        var text = resp.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        if (!resp.IsSuccessStatusCode)
            throw new HttpRequestException($"{(int)resp.StatusCode} {resp.ReasonPhrase} from {url}");
        return text;
    }

    // The schema JSON is delivered as a single string cell in the first table.
    private static string ExtractCell(string rawResponse)
    {
        var table = PrimaryTable(rawResponse);
        if (table.Rows is not { Count: > 0 } rows || rows[0].Count == 0)
            throw new InvalidOperationException("schema response had no rows.");
        return rows[0][0].GetString()
            ?? throw new InvalidOperationException("schema cell was not a string.");
    }

    private static KustoV1Table PrimaryTable(string rawResponse)
    {
        var resp = JsonSerializer.Deserialize(rawResponse, KqlGuardSarifContext.Default.KustoV1Response);
        var tables = resp?.Tables;
        if (tables is not { Count: > 0 })
            throw new InvalidOperationException("response had no Tables (is this a Kusto v1 REST reply?).");
        return tables.FirstOrDefault(t => t.Rows is { Count: > 0 }) ?? tables[0];
    }

    internal static (Dictionary<string, List<SchemaColumn>>, List<SchemaFunction>) ParseSchema(
        string innerJson, string database)
    {
        var root = JsonSerializer.Deserialize(innerJson, KqlGuardSarifContext.Default.ShowSchemaRoot);
        var dbs = root?.Databases ?? new();
        var db = dbs.TryGetValue(database, out var match) ? match : dbs.Values.FirstOrDefault();

        var tables = new Dictionary<string, List<SchemaColumn>>();
        foreach (var (name, table) in db?.Tables ?? new())
        {
            tables[name] = (table.OrderedColumns ?? new())
                .Select(c => new SchemaColumn(c.Name ?? "", CslType(c)))
                .ToList();
        }

        var functions = new List<SchemaFunction>();
        foreach (var (name, fn) in db?.Functions ?? new())
        {
            var parameters = "(" + string.Join(", ",
                (fn.InputParameters ?? new()).Select(p => $"{p.Name}: {CslType(p)}")) + ")";
            functions.Add(new SchemaFunction(fn.Name ?? name, parameters, fn.Body ?? "{ }"));
        }
        return (tables, functions);
    }

    // Prefer the server's CslType; otherwise map the .NET type name to a keyword.
    private static string CslType(ShowSchemaField f) =>
        !string.IsNullOrEmpty(f.CslType) ? f.CslType : SchemaLoader.MapType(f.Type ?? "");

    internal static Dictionary<string, int> ParseSizes(string rawResponse, long? baseline)
    {
        var table = PrimaryTable(rawResponse);
        int nameIdx = ColumnIndex(table, "TableName");
        int sizeIdx = ColumnIndex(table, "TotalOriginalSize");

        var sizes = new Dictionary<string, double>();
        foreach (var row in table.Rows ?? new())
        {
            if (nameIdx >= row.Count || sizeIdx >= row.Count) continue;
            var name = row[nameIdx].GetString();
            if (name != null) sizes[name] = ReadNumber(row[sizeIdx]);
        }

        double bl = baseline ?? Median(sizes.Values);
        if (bl <= 0) bl = 1;

        // factor = max(1, round(size / baseline)): the same integer multiplier
        // TableSizeEnricher already applies to scan-cost rules.
        return sizes.ToDictionary(kv => kv.Key, kv => (int)Math.Max(1, Math.Round(kv.Value / bl)));
    }

    private static int ColumnIndex(KustoV1Table table, string name)
    {
        var cols = table.Columns ?? new();
        for (int i = 0; i < cols.Count; i++)
            if (string.Equals(cols[i].ColumnName, name, StringComparison.OrdinalIgnoreCase)) return i;
        throw new InvalidOperationException($"column '{name}' not found in response.");
    }

    private static double ReadNumber(JsonElement cell) => cell.ValueKind switch
    {
        JsonValueKind.Number => cell.GetDouble(),
        JsonValueKind.String when double.TryParse(cell.GetString(), out var v) => v,
        _ => 0
    };

    private static double Median(IEnumerable<double> values)
    {
        var xs = values.Where(v => v > 0).OrderBy(v => v).ToList();
        return xs.Count == 0 ? 1 : xs[xs.Count / 2];
    }
}
