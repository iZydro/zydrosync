using System.Globalization;
using System.Text.Json;

namespace ZydroSync.Api.Workouts;

public sealed class PayloadValidationException(string message) : Exception(message);

/// <summary>Lo que el servidor extrae del payload para indexar. El resto se guarda en bruto.</summary>
public sealed record WorkoutSummary(
    Guid WorkoutId,
    int SchemaVersion,
    string Sport,
    DateTimeOffset StartDate,
    DateTimeOffset EndDate,
    double DurationSec,
    double? DistanceM,
    bool Indoor,
    string SourceBundleId,
    string? SourceProductType,
    int RoutePoints);

/// <summary>
/// Valida el payload contra lo que exige contract/openapi.yaml (WorkoutUpload) y extrae el resumen.
///
/// Lector tolerante: se exigen los campos obligatorios con su tipo, pero se aceptan campos
/// desconocidos. Así una app más nueva que añada un campo opcional no rompe con un servidor
/// más viejo. Lo que cambie la semántica irá en un schemaVersion nuevo.
/// </summary>
public static class WorkoutPayloadParser
{
    public const int SupportedSchemaVersion = 1;

    private static readonly JsonDocumentOptions Options = new() { MaxDepth = 16 };

    /// <exception cref="JsonException">JSON mal formado (→ 400).</exception>
    /// <exception cref="PayloadValidationException">JSON válido que no cumple el contrato (→ 422).</exception>
    public static WorkoutSummary Parse(byte[] json)
    {
        using var doc = JsonDocument.Parse(json, Options);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new PayloadValidationException("El cuerpo debe ser un objeto JSON");
        }

        var schemaVersion = RequiredInt(root, "schemaVersion");
        if (schemaVersion != SupportedSchemaVersion)
        {
            throw new PayloadValidationException($"schemaVersion {schemaVersion} no soportada (se admite {SupportedSchemaVersion})");
        }

        if (!Guid.TryParse(RequiredString(root, "workoutId"), out var workoutId))
        {
            throw new PayloadValidationException("workoutId debe ser un UUID");
        }

        var sport = RequiredString(root, "sport");
        if (sport.Length is 0 or > 40)
        {
            throw new PayloadValidationException("sport vacío o demasiado largo");
        }

        var start = RequiredDate(root, "startDate");
        var end = RequiredDate(root, "endDate");
        if (end < start)
        {
            throw new PayloadValidationException("endDate es anterior a startDate");
        }

        var duration = RequiredNonNegative(root, "durationSec");
        RequiredNonNegative(root, "elapsedSec");
        var indoor = Required(root, "indoor", JsonValueKind.True, JsonValueKind.False).GetBoolean();
        var distance = OptionalNonNegative(root, "distanceM");
        OptionalNonNegative(root, "activeEnergyKcal");

        var source = Required(root, "source", JsonValueKind.Object);
        var bundleId = RequiredString(source, "bundleId", "source.bundleId");
        RequiredString(source, "name", "source.name");
        var productType = OptionalString(source, "productType");

        Required(root, "series", JsonValueKind.Object);
        var routePoints = RoutePoints(root);

        return new WorkoutSummary(workoutId, schemaVersion, sport, start, end, duration, distance, indoor,
            bundleId, productType, routePoints);
    }

    /// <summary>La ruta es columnar: todos sus arrays deben tener la misma longitud que `t`.</summary>
    private static int RoutePoints(JsonElement root)
    {
        if (!root.TryGetProperty("route", out var route) || route.ValueKind == JsonValueKind.Null)
        {
            return 0;
        }
        if (route.ValueKind != JsonValueKind.Object)
        {
            throw new PayloadValidationException("route debe ser un objeto o null");
        }

        var t = Required(route, "t", JsonValueKind.Array, path: "route.t").GetArrayLength();
        foreach (var name in new[] { "lat", "lon" })
        {
            Required(route, name, JsonValueKind.Array, path: $"route.{name}");
        }
        foreach (var property in route.EnumerateObject())
        {
            if (property.Name != "segmentStarts" && property.Value.ValueKind == JsonValueKind.Array
                && property.Value.GetArrayLength() != t)
            {
                throw new PayloadValidationException($"route.{property.Name} tiene {property.Value.GetArrayLength()} elementos y route.t {t}");
            }
        }
        return t;
    }

    private static JsonElement Required(JsonElement obj, string name, params JsonValueKind[] kinds) =>
        Required(obj, name, kinds, name);

    private static JsonElement Required(JsonElement obj, string name, JsonValueKind kind, string path) =>
        Required(obj, name, [kind], path);

    private static JsonElement Required(JsonElement obj, string name, JsonValueKind[] kinds, string path)
    {
        if (!obj.TryGetProperty(name, out var value))
        {
            throw new PayloadValidationException($"Falta {path}");
        }
        if (!kinds.Contains(value.ValueKind))
        {
            throw new PayloadValidationException($"{path} tiene un tipo incorrecto ({value.ValueKind})");
        }
        return value;
    }

    private static string RequiredString(JsonElement obj, string name, string? path = null) =>
        Required(obj, name, [JsonValueKind.String], path ?? name).GetString()!;

    private static string? OptionalString(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int RequiredInt(JsonElement obj, string name)
    {
        var value = Required(obj, name, JsonValueKind.Number);
        return value.TryGetInt32(out var i) ? i : throw new PayloadValidationException($"{name} debe ser entero");
    }

    private static double RequiredNonNegative(JsonElement obj, string name)
    {
        var value = Required(obj, name, JsonValueKind.Number).GetDouble();
        return value >= 0 ? value : throw new PayloadValidationException($"{name} no puede ser negativo");
    }

    private static double? OptionalNonNegative(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var v) || v.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (v.ValueKind != JsonValueKind.Number || v.GetDouble() < 0)
        {
            throw new PayloadValidationException($"{name} debe ser un número ≥ 0 o null");
        }
        return v.GetDouble();
    }

    private static DateTimeOffset RequiredDate(JsonElement obj, string name)
    {
        var text = RequiredString(obj, name);
        if (!DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var date))
        {
            throw new PayloadValidationException($"{name} no es una fecha ISO 8601");
        }
        // Siempre en UTC: las fechas se guardan como entero y así su orden es el cronológico.
        return date.ToUniversalTime();
    }
}
