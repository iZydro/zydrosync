using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Workouts;

public sealed class IngestOptions
{
    /// <summary>Cuerpo tal cual llega (gzip). Un maratón son ~350 KB.</summary>
    public int MaxRequestBytes { get; set; } = 10 * 1024 * 1024;
    /// <summary>JSON descomprimido. Protege de "bombas gzip" (KB que se expanden a GB).</summary>
    public int MaxJsonBytes { get; set; } = 20 * 1024 * 1024;
}

public sealed record IngestResult(Guid WorkoutId, string Status, string? ServerId);

public static class WorkoutIngest
{
    public const string RateLimitPolicy = "per-token";

    public static IEndpointRouteBuilder MapWorkoutIngest(this IEndpointRouteBuilder app)
    {
        app.MapPost("/v1/workouts", HandleAsync)
            .RequireAuthorization(Policies.Device)
            .RequireRateLimiting(RateLimitPolicy);
        // "Cerrar sesión" en la app: el token de dispositivo se revoca a sí mismo.
        app.MapDelete("/v1/device/token", RevokeOwnTokenAsync)
            .RequireAuthorization(Policies.Device)
            .RequireRateLimiting(RateLimitPolicy);
        return app;
    }

    private sealed class PayloadTooLargeException : Exception;

    private static async Task<IResult> RevokeOwnTokenAsync(HttpContext http, DirectoryDb directory, TimeProvider time, CancellationToken ct)
    {
        var tokenId = Guid.Parse(http.User.FindFirst(BearerTokenHandler.TokenIdClaim)!.Value);
        await directory.ApiTokens.Where(t => t.Id == tokenId && t.RevokedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(t => t.RevokedAt, time.GetUtcNow()), ct);
        return Results.NoContent();
    }

    /// <summary>
    /// Idempotente por (usuario, workoutId):
    /// - nueva → 201 "created";
    /// - mismo contenido (SHA-256 del JSON) → 200 "duplicate", sin escribir;
    /// - contenido distinto → 200 "updated": se guarda la versión nueva con un seq nuevo,
    ///   para que el importador la vea.
    /// </summary>
    private static async Task<IResult> HandleAsync(HttpContext http, DataStore store, TimeProvider time,
        IOptions<IngestOptions> options, CancellationToken ct)
    {
        var limits = options.Value;
        var request = http.Request;

        if (!Guid.TryParse(request.Headers["Idempotency-Key"], out var key))
        {
            return Problem(400, "Falta la cabecera Idempotency-Key o no es un UUID");
        }
        if (!(request.ContentType?.StartsWith("application/json", StringComparison.OrdinalIgnoreCase) ?? false))
        {
            return Problem(415, "Content-Type debe ser application/json");
        }
        var encoding = request.Headers.ContentEncoding.ToString().Trim().ToLowerInvariant();
        if (encoding is not ("" or "identity" or "gzip"))
        {
            return Problem(415, $"Content-Encoding '{encoding}' no soportado (gzip o identity)");
        }
        if (request.ContentLength > limits.MaxRequestBytes)
        {
            return Problem(413, $"El cuerpo supera {limits.MaxRequestBytes} bytes");
        }

        byte[] body, json;
        try
        {
            body = await ReadLimitedAsync(request.Body, limits.MaxRequestBytes, ct);
            json = encoding == "gzip" ? Gunzip(body, limits.MaxJsonBytes) : body;
        }
        catch (PayloadTooLargeException)
        {
            return Problem(413, "El cuerpo (o su versión descomprimida) supera el límite");
        }
        catch (InvalidDataException)
        {
            return Problem(400, "El cuerpo no es gzip válido");
        }

        WorkoutSummary summary;
        try
        {
            summary = WorkoutPayloadParser.Parse(json);
        }
        catch (JsonException e)
        {
            return Problem(400, $"JSON mal formado: {e.Message}");
        }
        catch (PayloadValidationException e)
        {
            return Problem(422, e.Message);
        }
        if (summary.WorkoutId != key)
        {
            return Problem(422, "workoutId no coincide con Idempotency-Key");
        }

        var userId = http.User.UserId();
        var hash = SHA256.HashData(json);
        var gzip = encoding == "gzip" ? body : Gzip(json);
        var now = time.GetUtcNow();

        // Un escritor por usuario a la vez (ver DataStore): el siguiente seq es max + 1 sin carreras.
        var gate = store.WriteLock(userId);
        await gate.WaitAsync(ct);
        try
        {
            await using var db = await store.OpenUserAsync(userId, ct);
            var existing = await db.Workouts.FirstOrDefaultAsync(w => w.WorkoutId == key, ct);
            if (existing is not null && existing.PayloadSha256.AsSpan().SequenceEqual(hash))
            {
                return Results.Ok(new IngestResult(key, "duplicate", existing.Seq.ToString()));
            }

            var seq = (await db.Workouts.MaxAsync(w => (long?)w.Seq, ct) ?? 0) + 1;
            if (existing is not null)
            {
                Apply(existing, summary, gzip, hash, json.Length);
                existing.Seq = seq;
                existing.UpdatedAt = now;
                await db.SaveChangesAsync(ct);
                return Results.Ok(new IngestResult(key, "updated", seq.ToString()));
            }

            var workout = new Workout
            {
                WorkoutId = key,
                Sport = summary.Sport,
                SourceBundleId = summary.SourceBundleId,
                PayloadGzip = gzip,
                PayloadSha256 = hash,
                Seq = seq,
                ReceivedAt = now,
                UpdatedAt = now,
            };
            Apply(workout, summary, gzip, hash, json.Length);
            db.Workouts.Add(workout);
            await db.SaveChangesAsync(ct);
            return Results.Created($"/v1/workouts/{key}", new IngestResult(key, "created", seq.ToString()));
        }
        finally
        {
            gate.Release();
        }
    }

    private static void Apply(Workout w, WorkoutSummary s, byte[] gzip, byte[] hash, int jsonBytes)
    {
        w.SchemaVersion = s.SchemaVersion;
        w.Sport = s.Sport;
        w.StartDate = s.StartDate;
        w.EndDate = s.EndDate;
        w.DurationSec = s.DurationSec;
        w.DistanceM = s.DistanceM;
        w.Indoor = s.Indoor;
        w.SourceBundleId = s.SourceBundleId;
        w.SourceProductType = s.SourceProductType;
        w.RoutePoints = s.RoutePoints;
        w.PayloadGzip = gzip;
        w.PayloadSha256 = hash;
        w.PayloadJsonBytes = jsonBytes;
    }

    private static async Task<byte[]> ReadLimitedAsync(Stream stream, int max, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = await stream.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > max)
            {
                throw new PayloadTooLargeException();
            }
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    /// <summary>Descompresión en streaming con tope: nunca se materializa más de `max` bytes.</summary>
    private static byte[] Gunzip(byte[] gzip, int max)
    {
        using var input = new GZipStream(new MemoryStream(gzip), CompressionMode.Decompress);
        using var output = new MemoryStream();
        var chunk = new byte[81920];
        int read;
        while ((read = input.Read(chunk)) > 0)
        {
            if (output.Length + read > max)
            {
                throw new PayloadTooLargeException();
            }
            output.Write(chunk, 0, read);
        }
        return output.ToArray();
    }

    private static byte[] Gzip(byte[] data)
    {
        using var output = new MemoryStream();
        using (var gz = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
        {
            gz.Write(data);
        }
        return output.ToArray();
    }

    private static IResult Problem(int status, string detail) =>
        Results.Problem(statusCode: status, detail: detail);
}
