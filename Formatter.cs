using System;
using System.Collections.Generic;
using System.IO;
using Kusto.Language.Editor;

namespace KqlGuard;

/// <summary>
/// Deterministic KQL formatter — gofmt/Prettier for Kusto. Delegates to the
/// official Kusto.Language formatter (canonical pipe-per-line style) so output
/// is idempotent and matches the language authors' intent. No reinvented
/// pretty-printer.
/// </summary>
public static class Formatter
{
    private static readonly FormattingOptions Options =
        FormattingOptions.Default.WithPipeOperatorStyle(PlacementStyle.NewLine);

    public static string Format(string text) =>
        new KustoCodeService(text).GetFormattedText(Options).Text;

    /// <summary>
    /// fmt subcommand. Default: print formatted output. --write: rewrite files
    /// in place. --check: exit 1 if any file is not already formatted (CI gate).
    /// </summary>
    public static int Run(string[] args)
    {
        // args[0] == "fmt"; positional path at [1].
        if (args.Length < 2)
        {
            Console.Error.WriteLine("Usage: kql-guard fmt <path> [--write|--check]");
            return 2;
        }
        var target = args[1];
        bool write = false, check = false;
        for (int i = 2; i < args.Length; i++)
        {
            if (args[i] == "--write") write = true;
            else if (args[i] == "--check") check = true;
            else { Console.Error.WriteLine($"Unrecognized argument: {args[i]}"); return 2; }
        }
        if (write && check) { Console.Error.WriteLine("--write and --check are mutually exclusive."); return 2; }

        if (!Program.TryResolveFiles(target, out var files)) return 2;

        bool anyUnformatted = false;
        foreach (var file in files)
        {
            var original = File.ReadAllText(file);
            var formatted = Format(original);
            if (formatted == original) continue;

            if (write)
            {
                File.WriteAllText(file, formatted);
                Console.WriteLine($"formatted {file}");
            }
            else if (check)
            {
                anyUnformatted = true;
                Console.WriteLine($"would reformat {file}");
            }
            else if (files.Length == 1)
            {
                Console.Write(formatted);
            }
            else
            {
                Console.WriteLine($"=== {file} ===");
                Console.Write(formatted);
            }
        }
        return (check && anyUnformatted) ? 1 : 0;
    }
}
