using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace KqlGuard;

// Lightweight SARIF v2.1.0 record types for NativeAOT-safe serialization.
// Only the subset required by GitHub Advanced Security is modeled.

public sealed record SarifLog(
    [property: JsonPropertyName("$schema")] string? Schema,
    string Version,
    List<SarifRun> Runs);

public sealed record SarifRun(
    SarifTool Tool,
    List<SarifResult> Results,
    string? ColumnKind = null);

public sealed record SarifTool(
    SarifToolComponent Driver);

public sealed record SarifToolComponent(
    string Name,
    string? Version = null,
    string? SemanticVersion = null,
    string? InformationUri = null,
    List<SarifReportingDescriptor>? Rules = null);

public sealed record SarifReportingDescriptor(
    string Id,
    string? Name = null,
    SarifMultiformatMessageString? ShortDescription = null,
    SarifMultiformatMessageString? FullDescription = null,
    SarifReportingConfiguration? DefaultConfiguration = null,
    string? HelpUri = null);

public sealed record SarifMultiformatMessageString(
    string Text);

public sealed record SarifReportingConfiguration(
    string Level);

public sealed record SarifResult(
    string RuleId,
    int RuleIndex,
    string Level,
    SarifMessage Message,
    List<SarifLocation>? Locations = null);

public sealed record SarifMessage(
    string Text);

public sealed record SarifLocation(
    SarifPhysicalLocation? PhysicalLocation = null);

public sealed record SarifPhysicalLocation(
    SarifArtifactLocation? ArtifactLocation = null,
    SarifRegion? Region = null);

public sealed record SarifArtifactLocation(
    string? Uri = null);

public sealed record SarifRegion(
    int StartLine,
    int StartColumn);

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    WriteIndented = true)]
[JsonSerializable(typeof(SarifLog))]
internal partial class KqlGuardSarifContext : JsonSerializerContext;
