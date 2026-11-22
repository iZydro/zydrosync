using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Auth;

public static class Policies
{
    public const string Device = "device";
    public const string Integration = "integration";
    public const string Admin = "admin";
    /// <summary>Leer los entrenamientos propios: device, integration y web. El admin no (tiene su panel).</summary>
    public const string Reader = "reader";
}

/// <summary>
/// "Authorization: Bearer &lt;token&gt;" → usuario + tipo de token. Las respuestas 401/403 son
/// problem+json (RFC 9457), como el resto de errores de la API.
/// </summary>
public sealed class BearerTokenHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    DirectoryDb db,
    TimeProvider time) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "Bearer";
    public const string KindClaim = "zs:kind";
    public const string TokenIdClaim = "zs:tid";

    /// <summary>No se escribe LastUsedAt en cada petición: una vez cada 5 minutos basta.</summary>
    private static readonly TimeSpan LastUsedResolution = TimeSpan.FromMinutes(5);

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        string? header = Request.Headers.Authorization;
        if (string.IsNullOrEmpty(header) || !header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return AuthenticateResult.NoResult();
        }

        var secret = header["Bearer ".Length..].Trim();
        if (secret.Length is 0 or > 200)
        {
            return AuthenticateResult.Fail("Token mal formado");
        }

        var hash = TokenService.Hash(secret);
        var token = await db.ApiTokens.AsNoTracking()
            .FirstOrDefaultAsync(t => t.Hash == hash && t.RevokedAt == null, Context.RequestAborted);
        if (token is null)
        {
            return AuthenticateResult.Fail("Token no válido o revocado");
        }

        var now = time.GetUtcNow();
        if (token.LastUsedAt is null || now - token.LastUsedAt > LastUsedResolution)
        {
            await db.ApiTokens.Where(t => t.Id == token.Id)
                .ExecuteUpdateAsync(s => s.SetProperty(t => t.LastUsedAt, now), Context.RequestAborted);
        }

        Claim[] claims =
        [
            new(ClaimTypes.NameIdentifier, token.UserId.ToString()),
            new(KindClaim, token.Kind.ToString()),
            new(TokenIdClaim, token.Id.ToString()),
        ];
        var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, SchemeName));
        return AuthenticateResult.Success(new AuthenticationTicket(principal, SchemeName));
    }

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.Headers.WWWAuthenticate = "Bearer";
        return Results.Problem(statusCode: StatusCodes.Status401Unauthorized, title: "Unauthorized",
            detail: "Falta el token o no es válido").ExecuteAsync(Context);
    }

    protected override Task HandleForbiddenAsync(AuthenticationProperties properties) =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Forbidden",
            detail: "Este tipo de token no tiene permiso para esta operación").ExecuteAsync(Context);
}

public static class ClaimsPrincipalExtensions
{
    public static Guid UserId(this ClaimsPrincipal user) =>
        Guid.Parse(user.FindFirstValue(ClaimTypes.NameIdentifier) ?? throw new InvalidOperationException("Sin usuario"));
}
