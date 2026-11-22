using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;
using ZydroSync.Api.Workouts;

namespace ZydroSync.Api.Admin;

public sealed class AdminOptions
{
    /// <summary>
    /// Desactivado por defecto: en producción ni siquiera existen las rutas /admin (404).
    /// Si se activa, lo recomendado es no publicarlo en el proxy y entrar por túnel SSH.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>
    /// Solo responde a peticiones con Host localhost / 127.0.0.1 / [::1], es decir, las que
    /// llegan por el túnel SSH. Las que pasan por Caddy llevan Host sync.isidrogilabert.com
    /// (Caddy solo enruta ese dominio) y reciben 404, aunque Caddy ya las corta antes.
    /// Activado en producción; en desarrollo da igual.
    /// </summary>
    public bool LocalhostOnly { get; set; }
}

public sealed record CreateUserRequest(string Email);
public sealed record CreateTokenRequest(string Kind, string? Name);
/// <summary>El secreto solo viaja en esta respuesta: no se guarda en claro ni se vuelve a mostrar.</summary>
public sealed record CreatedTokenDto(AdminTokenDto Token, string Secret);

public sealed record AdminTokenDto(Guid Id, string Kind, string Prefix, string Name,
    DateTimeOffset CreatedAt, DateTimeOffset? LastUsedAt, DateTimeOffset? RevokedAt);

public sealed record AdminUserDto(Guid Id, string Email, DateTimeOffset CreatedAt, int Workouts,
    DateTimeOffset? LastWorkoutStart, long DataBytes, IReadOnlyList<AdminTokenDto> Tokens);

public sealed record AdminWorkoutDto(Guid WorkoutId, long Seq, string Sport, DateTimeOffset StartDate,
    DateTimeOffset EndDate, double DurationSec, double? DistanceM, bool Indoor, string? SourceProductType,
    int RoutePoints, int PayloadGzipBytes, int PayloadJsonBytes, DateTimeOffset ReceivedAt, DateTimeOffset UpdatedAt);

/// <summary>
/// Panel de administración: ficheros estáticos en wwwroot/admin y API JSON en /admin/api.
/// Solo con token de tipo admin (los de dispositivo e integración reciben 403).
/// </summary>
public static class AdminPanel
{
    /// <summary>
    /// Va al principio de la cadena, antes de la autenticación: desde fuera del túnel, /admin
    /// da 404 (ni siquiera 401) y no se consulta ningún token.
    /// </summary>
    public static WebApplication UseAdminLocalhostOnly(this WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptions<AdminOptions>>().Value;
        if (options.Enabled && options.LocalhostOnly)
        {
            app.Use(async (ctx, next) =>
            {
                if (ctx.Request.Path.StartsWithSegments("/admin") && !IsLocalhost(ctx.Request.Host.Host))
                {
                    ctx.Response.StatusCode = StatusCodes.Status404NotFound;
                    return;
                }
                await next();
            });
        }
        return app;
    }

    public static WebApplication MapAdminPanel(this WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptions<AdminOptions>>().Value;
        if (!options.Enabled)
        {
            return app;
        }

        var adminFiles = new PhysicalFileProvider(Path.Combine(app.Environment.WebRootPath ?? "wwwroot", "admin"));
        // "/admin" → "/admin/" (las rutas relativas del index.html lo necesitan). No se usa
        // MapGet porque el enrutado ignora la barra final y también capturaría "/admin/".
        app.Use(async (ctx, next) =>
        {
            if (ctx.Request.Path.Value == "/admin")
            {
                ctx.Response.Redirect("/admin/");
                return;
            }
            await next();
        });
        app.UseDefaultFiles(new DefaultFilesOptions { RequestPath = "/admin", FileProvider = adminFiles });
        app.UseStaticFiles(new StaticFileOptions { RequestPath = "/admin", FileProvider = adminFiles });

        var api = app.MapGroup("/admin/api").RequireAuthorization(Policies.Admin);

        api.MapGet("/users", ListUsersAsync);
        api.MapPost("/users", CreateUserAsync);
        api.MapPost("/users/{userId:guid}/tokens", CreateTokenAsync);
        api.MapPost("/tokens/{tokenId:guid}/revoke", RevokeTokenAsync);
        api.MapGet("/users/{userId:guid}/workouts", ListWorkoutsAsync);
        api.MapGet("/users/{userId:guid}/workouts/{workoutId:guid}", GetWorkoutJsonAsync);
        api.MapDelete("/users/{userId:guid}/workouts/{workoutId:guid}", DeleteWorkoutAsync);
        return app;
    }

    private static async Task<IResult> ListUsersAsync(DirectoryDb directory, DataStore store, CancellationToken ct)
    {
        var users = await directory.Users.AsNoTracking().Include(u => u.Tokens).ToListAsync(ct);
        var result = new List<AdminUserDto>(users.Count);
        foreach (var u in users.OrderBy(u => u.Email))
        {
            var count = 0;
            DateTimeOffset? last = null;
            long bytes = 0;
            if (store.UserDbExists(u.Id))
            {
                await using var db = await store.OpenUserAsync(u.Id, ct);
                var starts = await db.Workouts.Select(w => w.StartDate).ToListAsync(ct);
                count = starts.Count;
                last = starts.Count > 0 ? starts.Max() : null;
                bytes = new FileInfo(store.UserDbPath(u.Id)).Length;
            }
            var tokens = u.Tokens.OrderBy(t => t.CreatedAt).Select(ToDto).ToList();
            result.Add(new AdminUserDto(u.Id, u.Email, u.CreatedAt, count, last, bytes, tokens));
        }
        return Results.Ok(result);
    }

    private static bool IsLocalhost(string host) =>
        host is "localhost" or "127.0.0.1" or "[::1]" or "::1";

    private static AdminTokenDto ToDto(ApiToken t) =>
        new(t.Id, t.Kind.ToString(), t.Prefix, t.Name, t.CreatedAt, t.LastUsedAt, t.RevokedAt);

    private static async Task<IResult> CreateUserAsync(CreateUserRequest request, DirectoryDb directory,
        TimeProvider time, CancellationToken ct)
    {
        var email = request.Email?.Trim().ToLowerInvariant() ?? "";
        // Validación mínima: es un identificador para el administrador, no se envía correo.
        if (email.Length is < 3 or > 320 || email.Count(c => c == '@') != 1 || email.StartsWith('@') || email.EndsWith('@')
            || email.Any(char.IsWhiteSpace))
        {
            return Results.Problem(statusCode: 400, detail: "Email no válido");
        }
        if (await directory.Users.AnyAsync(u => u.Email == email, ct))
        {
            return Results.Problem(statusCode: 409, detail: $"Ya existe el usuario {email}");
        }
        var user = new User { Id = Guid.CreateVersion7(), Email = email, CreatedAt = time.GetUtcNow() };
        directory.Users.Add(user);
        await directory.SaveChangesAsync(ct);
        return Results.Created($"/admin/api/users/{user.Id}",
            new AdminUserDto(user.Id, user.Email, user.CreatedAt, 0, null, 0, []));
    }

    private static async Task<IResult> CreateTokenAsync(Guid userId, CreateTokenRequest request, DirectoryDb directory,
        TokenService tokens, CancellationToken ct)
    {
        if (!Enum.TryParse<TokenKind>(request.Kind, ignoreCase: true, out var kind) || !Enum.IsDefined(kind)
            || int.TryParse(request.Kind, out _))
        {
            return Results.Problem(statusCode: 400, detail: "Tipo de token: device, integration, web o admin");
        }
        var name = string.IsNullOrWhiteSpace(request.Name) ? kind.ToString() : request.Name.Trim();
        if (name.Length > 100)
        {
            return Results.Problem(statusCode: 400, detail: "Nombre demasiado largo (100 caracteres)");
        }
        if (!await directory.Users.AnyAsync(u => u.Id == userId, ct))
        {
            return Results.NotFound();
        }
        var (token, secret) = await tokens.CreateAsync(userId, kind, name, ct);
        return Results.Ok(new CreatedTokenDto(ToDto(token), secret));
    }

    private static async Task<IResult> RevokeTokenAsync(Guid tokenId, DirectoryDb directory, TimeProvider time, CancellationToken ct)
    {
        var revoked = await directory.ApiTokens.Where(t => t.Id == tokenId && t.RevokedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(t => t.RevokedAt, time.GetUtcNow()), ct);
        return revoked == 1 ? Results.NoContent() : Results.NotFound();
    }

    private static async Task<IResult> ListWorkoutsAsync(Guid userId, DirectoryDb directory, DataStore store,
        int? limit, CancellationToken ct)
    {
        if (!await directory.Users.AnyAsync(u => u.Id == userId, ct))
        {
            return Results.NotFound();
        }
        if (!store.UserDbExists(userId))
        {
            return Results.Ok(Array.Empty<AdminWorkoutDto>());
        }
        await using var db = await store.OpenUserAsync(userId, ct);
        // Sin traer el payload: solo las columnas de resumen.
        var rows = await db.Workouts.AsNoTracking()
            .Select(w => new AdminWorkoutDto(w.WorkoutId, w.Seq, w.Sport, w.StartDate, w.EndDate, w.DurationSec,
                w.DistanceM, w.Indoor, w.SourceProductType, w.RoutePoints, w.PayloadGzip.Length, w.PayloadJsonBytes,
                w.ReceivedAt, w.UpdatedAt))
            .ToListAsync(ct);
        return Results.Ok(rows.OrderByDescending(w => w.StartDate).Take(Math.Clamp(limit ?? 500, 1, 5000)));
    }

    /// <summary>El payload original (comprimido si el cliente acepta gzip).</summary>
    private static async Task<IResult> GetWorkoutJsonAsync(Guid userId, Guid workoutId, HttpContext http,
        DataStore store, CancellationToken ct)
    {
        if (!store.UserDbExists(userId))
        {
            return Results.NotFound();
        }
        await using var db = await store.OpenUserAsync(userId, ct);
        var gzip = await db.Workouts.Where(w => w.WorkoutId == workoutId).Select(w => w.PayloadGzip).FirstOrDefaultAsync(ct);
        if (gzip is null)
        {
            return Results.NotFound();
        }
        return WorkoutRead.Payload(http, gzip);
    }

    private static async Task<IResult> DeleteWorkoutAsync(Guid userId, Guid workoutId, DataStore store, CancellationToken ct)
    {
        if (!store.UserDbExists(userId))
        {
            return Results.NotFound();
        }
        var gate = store.WriteLock(userId);
        await gate.WaitAsync(ct);
        try
        {
            await using var db = await store.OpenUserAsync(userId, ct);
            var deleted = await db.Workouts.Where(w => w.WorkoutId == workoutId).ExecuteDeleteAsync(ct);
            return deleted == 1 ? Results.NoContent() : Results.NotFound();
        }
        finally
        {
            gate.Release();
        }
    }
}
