using System.IO.Compression;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ZydroSync.Api.Tests;

/// <summary>
/// Payloads SINTÉTICOS con la forma que genera la app (ver ios/.../WorkoutMapper.swift).
/// Deliberadamente no se usan carreras reales: llevan datos de salud y la ruta GPS de
/// alguien, y no deben quedar en el historial de git.
/// </summary>
public static class Payloads
{
    public static JsonObject Valid(Guid id, int routePoints = 3) => new()
    {
        ["schemaVersion"] = 1,
        ["workoutId"] = id.ToString().ToUpperInvariant(),
        ["sport"] = "running",
        ["indoor"] = false,
        ["startDate"] = "2026-11-20T07:00:00.000Z",
        ["endDate"] = "2026-11-20T07:30:00.000Z",
        ["timeZone"] = "Europe/Madrid",
        ["durationSec"] = 1800.0,
        ["elapsedSec"] = 1800.0,
        ["distanceM"] = 5012.34,
        ["activeEnergyKcal"] = 300.5,
        ["source"] = new JsonObject
        {
            ["bundleId"] = "com.apple.health.00000000-0000-0000-0000-000000000000",
            ["name"] = "Apple Watch",
            ["productType"] = "Watch7,12",
        },
        ["events"] = new JsonArray(),
        ["route"] = routePoints == 0 ? null : new JsonObject
        {
            ["t"] = Numbers(routePoints, i => i),
            ["lat"] = Numbers(routePoints, i => 40.0 + i * 1e-5),
            ["lon"] = Numbers(routePoints, i => -3.0 - i * 1e-5),
            ["alt"] = Numbers(routePoints, _ => 650.0),
        },
        ["series"] = new JsonObject
        {
            ["heartRate"] = new JsonObject { ["t"] = Numbers(2, i => i * 5), ["v"] = Numbers(2, _ => 150) },
        },
    };

    public static byte[] Json(JsonNode payload) => JsonSerializer.SerializeToUtf8Bytes(payload);

    public static byte[] Gzip(byte[] data)
    {
        using var output = new MemoryStream();
        using (var gz = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
        {
            gz.Write(data);
        }
        return output.ToArray();
    }

    public static byte[] Gunzip(byte[] data)
    {
        using var input = new GZipStream(new MemoryStream(data), CompressionMode.Decompress);
        using var output = new MemoryStream();
        input.CopyTo(output);
        return output.ToArray();
    }

    public static HttpRequestMessage Post(Guid? idempotencyKey, byte[] body, string? encoding = "gzip",
        string contentType = "application/json")
    {
        var content = new ByteArrayContent(body);
        content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
        if (encoding is not null)
        {
            content.Headers.ContentEncoding.Add(encoding);
        }
        var request = new HttpRequestMessage(HttpMethod.Post, "/v1/workouts") { Content = content };
        if (idempotencyKey is { } key)
        {
            request.Headers.Add("Idempotency-Key", key.ToString());
        }
        return request;
    }

    public static HttpRequestMessage PostGzip(Guid id, JsonNode payload) => Post(id, Gzip(Json(payload)));

    private static JsonArray Numbers(int count, Func<int, double> f) =>
        new(Enumerable.Range(0, count).Select(i => (JsonNode?)JsonValue.Create(f(i))).ToArray());
}
