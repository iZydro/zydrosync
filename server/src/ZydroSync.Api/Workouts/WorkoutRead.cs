using System.IO.Compression;
using Microsoft.EntityFrameworkCore;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Workouts;

/// <summary>Resumen de un entrenamiento, sin el payload. <c>serverId</c> es el cursor (seq).</summary>
public sealed record WorkoutSummaryDto(Guid WorkoutId, string ServerId, string Sport, DateTimeOffset StartDate,
    DateTimeOffset EndDate, double DurationSec, double? DistanceM, bool Indoor, string? SourceProductType,
    int RoutePoints, DateTimeOffset ReceivedAt, DateTimeOffset UpdatedAt);

/// <summary>
/// <c>nextAfter</c> es el valor de <c>after</c> para la página siguiente, o null si no hay más.
/// Un importador guarda el último <c>serverId</c> que procesó y pide <c>after=</c> ese valor:
/// recibe lo nuevo y también lo actualizado, porque una actualización asigna un seq nuevo.
/// </summary>
public sealed record WorkoutPage(IReadOnlyList<WorkoutSummaryDto> Items, string? NextAfter);

/// <summary>
/// Lectura de los entrenamientos del propio usuario: la web «Mis carreras», el importador de
/// ZydroTrack (S3) y, en el futuro, la app. Cada token solo ve el fichero de su usuario.
/// </summary>
public static class WorkoutRead
{
    public const int DefaultLimit = 100;
    public const int MaxLimit = 500;

    public static IEndpointRouteBuilder MapWorkoutRead(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/v1/workouts")
            .RequireAuthorization(Policies.Reader)
            .RequireRateLimiting(WorkoutIngest.RateLimitPolicy);
        group.MapGet("", ListAsync);
        group.MapGet("/{workoutId:guid}", GetAsync);
        return app;
    }

    private static async Task<IResult> ListAsync(HttpContext http, DataStore store, string? after, int? limit,
        CancellationToken ct)
    {
        long cursor = 0;
        if (after is not null && (!long.TryParse(after, out cursor) || cursor < 0))
        {
            return Results.Problem(statusCode: 400, detail: "after debe ser un serverId devuelto por la API");
        }
        if (limit is < 1 or > MaxLimit)
        {
            return Results.Problem(statusCode: 400, detail: $"limit debe estar entre 1 y {MaxLimit}");
        }
        var take = limit ?? DefaultLimit;

        var userId = http.User.UserId();
        if (!store.UserDbExists(userId))
        {
            return Results.Ok(new WorkoutPage([], null));
        }
        await using var db = await store.OpenUserAsync(userId, ct);
        // Uno de más para saber si hay otra página sin un COUNT aparte.
        var rows = await db.Workouts.AsNoTracking()
            .Where(w => w.Seq > cursor)
            .OrderBy(w => w.Seq)
            .Take(take + 1)
            .Select(w => new WorkoutSummaryDto(w.WorkoutId, w.Seq.ToString(), w.Sport, w.StartDate, w.EndDate,
                w.DurationSec, w.DistanceM, w.Indoor, w.SourceProductType, w.RoutePoints, w.ReceivedAt, w.UpdatedAt))
            .ToListAsync(ct);
        var hasMore = rows.Count > take;
        var items = hasMore ? rows[..take] : rows;
        return Results.Ok(new WorkoutPage(items, hasMore ? items[^1].ServerId : null));
    }

    private static async Task<IResult> GetAsync(Guid workoutId, HttpContext http, DataStore store, CancellationToken ct)
    {
        var userId = http.User.UserId();
        if (!store.UserDbExists(userId))
        {
            return NotFound();
        }
        await using var db = await store.OpenUserAsync(userId, ct);
        var gzip = await db.Workouts.Where(w => w.WorkoutId == workoutId).Select(w => w.PayloadGzip).FirstOrDefaultAsync(ct);
        return gzip is null ? NotFound() : Payload(http, gzip);
    }

    private static IResult NotFound() => Results.Problem(statusCode: 404, detail: "No existe ese entrenamiento");

    /// <summary>
    /// El payload tal cual se guardó. Si el cliente acepta gzip (navegadores, y HttpClient con
    /// descompresión automática) se envía comprimido sin tocarlo; si no, se descomprime aquí.
    /// </summary>
    public static IResult Payload(HttpContext http, byte[] gzip)
    {
        http.Response.Headers.Vary = "Accept-Encoding";
        var acceptsGzip = AcceptsGzip(http.Request.Headers.AcceptEncoding.ToString());
        if (acceptsGzip)
        {
            http.Response.Headers.ContentEncoding = "gzip";
            return Results.Bytes(gzip, "application/json");
        }
        using var input = new GZipStream(new MemoryStream(gzip), CompressionMode.Decompress);
        using var output = new MemoryStream();
        input.CopyTo(output);
        return Results.Bytes(output.ToArray(), "application/json");
    }

    /// <summary>"gzip" o "*" con q &gt; 0 (p. ej. "gzip, deflate, br" o "gzip;q=0.5", pero no "gzip;q=0").</summary>
    public static bool AcceptsGzip(string header)
    {
        foreach (var part in header.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var fields = part.Split(';', StringSplitOptions.TrimEntries);
            if (!fields[0].Equals("gzip", StringComparison.OrdinalIgnoreCase) && fields[0] != "*")
            {
                continue;
            }
            var q = fields.Skip(1).FirstOrDefault(f => f.StartsWith("q=", StringComparison.OrdinalIgnoreCase));
            if (q is null || (double.TryParse(q[2..], System.Globalization.NumberStyles.Float,
                    System.Globalization.CultureInfo.InvariantCulture, out var value) && value > 0))
            {
                return true;
            }
        }
        return false;
    }
}
