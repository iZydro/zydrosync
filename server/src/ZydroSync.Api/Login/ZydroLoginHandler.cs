using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Login;

/// <summary>
/// Autenticación con ZydroLogin, de dos formas:
/// - cookie de sesión de la web (zs_session) → el access token guardado en el servidor;
/// - "Authorization: Bearer &lt;access token de ZydroLogin&gt;" (otros backends, y la app en el futuro).
///
/// En ambos casos el access token se valida en CADA petición por introspección autenticada
/// (sin caché: una revocación se nota al instante). Si ZydroLogin no responde, se rechaza.
/// El usuario es el de ZydroSync vinculado a ese `sub`; un `sub` sin vincular no entra.
/// </summary>
public sealed class ZydroLoginHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    IOptions<ZydroLoginOptions> loginOptions,
    IOptions<ZydroSync.Api.Admin.AdminOptions> adminOptions,
    ZydroLoginClient login,
    LoginSessions sessions,
    DirectoryDb db) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "ZydroLogin";
    public const string ScopeClaim = "scope";
    public const string SessionClaim = "zs:session";
    /// <summary>Administrador por la web: sesión de admin + permiso zydrosync:admin + email en Admin:Emails.</summary>
    public const string AdminClaim = "zs:admin";
    public const string UnavailableItem = "zydrologin.unavailable";

    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!loginOptions.Value.Enabled)
        {
            return AuthenticateResult.NoResult();
        }
        var ct = Context.RequestAborted;
        string? header = Request.Headers.Authorization;
        if (header is not null && header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            var token = header["Bearer ".Length..].Trim();
            return token.Length is 0 or > 8192 ? AuthenticateResult.Fail("Token mal formado") : await FromAccessTokenAsync(token, null, ct);
        }

        if (!Request.Cookies.TryGetValue(LoginSessions.CookieName, out var cookie))
        {
            return AuthenticateResult.NoResult();
        }
        ActiveSession session;
        try
        {
            session = await sessions.ResolveAsync(cookie, ct);
        }
        catch (SessionInvalidException)
        {
            Response.Cookies.Delete(LoginSessions.CookieName, LoginEndpoints.SessionCookie(loginOptions.Value, TimeSpan.Zero));
            return AuthenticateResult.Fail("Sesión caducada o cerrada");
        }
        catch (LoginProviderException)
        {
            Context.Items[UnavailableItem] = true;
            return AuthenticateResult.Fail("ZydroLogin no disponible");
        }
        return await FromAccessTokenAsync(session.AccessToken, session, ct);
    }

    private async Task<AuthenticateResult> FromAccessTokenAsync(string token, ActiveSession? session, CancellationToken ct)
    {
        Introspection result;
        try
        {
            result = await login.IntrospectAsync(token, ct);
        }
        catch (LoginProviderException e) when (e.Failure == LoginFailure.Unavailable)
        {
            Context.Items[UnavailableItem] = true;
            return AuthenticateResult.Fail("ZydroLogin no disponible");
        }
        catch (LoginProviderException)
        {
            return AuthenticateResult.Fail("Token rechazado por ZydroLogin");
        }

        if (login.Validate(result) is { } reason)
        {
            if (session is not null && reason == "inactive")
            {
                // Revocado en ZydroLogin (o la lista de permitidos ya no incluye al usuario).
                await sessions.InvalidateAsync(session.Id, ct);
                Response.Cookies.Delete(LoginSessions.CookieName, LoginEndpoints.SessionCookie(loginOptions.Value, TimeSpan.Zero));
            }
            return AuthenticateResult.Fail($"Token no válido para ZydroSync ({reason})");
        }

        var user = await db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.LoginSubject == result.Subject, ct);
        if (user is null || (session is not null && (session.UserId != user.Id || session.Subject != result.Subject)))
        {
            return AuthenticateResult.Fail("Identidad no vinculada a un usuario de ZydroSync");
        }

        var identity = new ClaimsIdentity(SchemeName);
        identity.AddClaim(new(ClaimTypes.NameIdentifier, user.Id.ToString()));
        identity.AddClaim(new(ClaimTypes.Email, user.Email));
        identity.AddClaim(new(BearerTokenHandler.KindClaim, "Login"));
        // Partición del rate limit: por sesión, o por usuario si es un Bearer.
        identity.AddClaim(new(BearerTokenHandler.TokenIdClaim, session is null ? $"login:{user.Id}" : $"session:{session.Id}"));
        if (session is not null)
        {
            identity.AddClaim(new(SessionClaim, session.Id.ToString()));
        }
        foreach (var scope in result.Scopes)
        {
            identity.AddClaim(new(ScopeClaim, scope));
        }
        // Solo con sesión de navegador (no con un Bearer suelto), pedida como admin, con el
        // permiso concedido por ZydroLogin y con el email en la lista privada del servidor.
        if (session is { Admin: true } && result.Scopes.Contains(loginOptions.Value.AdminScope)
            && adminOptions.Value.IsAdminEmail(user.Email))
        {
            identity.AddClaim(new(AdminClaim, "true"));
        }
        return AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName));
    }

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        if (Context.Items.ContainsKey(UnavailableItem))
        {
            Response.Headers.RetryAfter = "30";
            return Results.Problem(statusCode: StatusCodes.Status503ServiceUnavailable, title: "Service Unavailable",
                detail: "ZydroLogin no responde: no se puede validar la sesión").ExecuteAsync(Context);
        }
        Response.Headers.WWWAuthenticate = "Bearer";
        return Results.Problem(statusCode: StatusCodes.Status401Unauthorized, title: "Unauthorized",
            detail: "Falta la sesión o el token, o no es válido").ExecuteAsync(Context);
    }

    protected override Task HandleForbiddenAsync(AuthenticationProperties properties) =>
        Results.Problem(statusCode: StatusCodes.Status403Forbidden, title: "Forbidden",
            detail: "Este acceso no tiene permiso para esta operación").ExecuteAsync(Context);
}
