using System.Buffers.Text;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Login;

/// <summary>
/// Inicio de sesión web con ZydroLogin (Authorization Code + PKCE S256, cliente confidencial):
///   GET  /auth/login      genera state y code_verifier, los guarda cifrados en una cookie
///                         temporal del navegador y redirige a ZydroLogin
///   GET  /auth/callback   comprueba state (e iss), canjea el código EN EL BACKEND, valida el
///                         perfil con userinfo, vincula el usuario y crea la sesión
///   POST /auth/logout     revoca los tokens y cierra la sesión de ZydroSync (no la de ZydroLogin)
///   GET  /auth/status     ¿hay sesión? Para la web. Nunca devuelve tokens.
///
/// Los errores del callback redirigen a /?login_error=&lt;código fijo&gt;: la web muestra un
/// mensaje y un botón; nunca se vuelve a redirigir sola al login (sin bucles).
/// </summary>
public static class LoginEndpoints
{
    public const string TransactionCookieName = "zs_login";
    private static readonly TimeSpan TransactionLifetime = TimeSpan.FromMinutes(10);
    private const string TransactionPurpose = "ZydroSync.Login.Transaction";

    private sealed record Transaction(string State, string Verifier, bool Admin = false, AppLoginRequest? App = null);

    public static CookieOptions SessionCookie(ZydroLoginOptions options, TimeSpan maxAge) => new()
    {
        HttpOnly = true,
        // Secure siempre que el sitio sea https (producción). En local por http no lo es, o
        // los clientes no la devolverían.
        Secure = options.CallbackUri?.StartsWith("https:", StringComparison.OrdinalIgnoreCase) ?? true,
        SameSite = SameSiteMode.Lax,
        Path = "/",
        MaxAge = maxAge,
        IsEssential = true,
    };

    private static CookieOptions TransactionCookie(ZydroLoginOptions options) => new()
    {
        HttpOnly = true,
        Secure = options.CallbackUri?.StartsWith("https:", StringComparison.OrdinalIgnoreCase) ?? true,
        // Lax: la vuelta desde ZydroLogin es una navegación de primer nivel (GET), que la envía.
        SameSite = SameSiteMode.Lax,
        Path = "/auth/callback",
        MaxAge = TransactionLifetime,
        IsEssential = true,
    };

    public static IEndpointRouteBuilder MapLoginEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/auth");
        group.MapGet("/status", StatusAsync);
        group.MapGet("/login", Login);
        group.MapGet("/app/start", AppLogin.Start);
        group.MapPost("/app/token", AppLogin.RedeemAsync).DisableAntiforgery();
        group.MapGet("/callback", CallbackAsync);
        group.MapPost("/logout", LogoutAsync);
        return app;
    }

    private static async Task<IResult> StatusAsync(HttpContext http, IOptions<ZydroLoginOptions> options)
    {
        if (!options.Value.Enabled || !http.Request.Cookies.ContainsKey(LoginSessions.CookieName))
        {
            return Results.Ok(new { loginEnabled = options.Value.Enabled, user = (object?)null });
        }
        var result = await http.AuthenticateAsync(ZydroLoginHandler.SchemeName);
        if (!result.Succeeded && http.Items.ContainsKey(ZydroLoginHandler.UnavailableItem))
        {
            return Results.Problem(statusCode: 503, detail: "ZydroLogin no responde: no se puede validar la sesión");
        }
        return Results.Ok(new
        {
            loginEnabled = true,
            user = result.Principal is { } user
                ? new { email = user.FindFirstValue(ClaimTypes.Email), isAdmin = user.HasClaim(ZydroLoginHandler.AdminClaim, "true") }
                : null,
        });
    }

    private static IResult Login(HttpContext http, IOptions<ZydroLoginOptions> options, IDataProtectionProvider protection,
        string? prompt, string? admin)
    {
        var o = options.Value;
        if (!o.Enabled)
        {
            return Results.NotFound();
        }
        return StartAuthorize(http, o, protection, prompt, admin == "1", app: null);
    }

    /// <summary>
    /// Guarda el intento (state, code_verifier y, si viene de la app, su petición) cifrado en
    /// una cookie de este navegador y redirige a ZydroLogin con PKCE S256.
    /// </summary>
    internal static IResult StartAuthorize(HttpContext http, ZydroLoginOptions o, IDataProtectionProvider protection,
        string? prompt, bool admin, AppLoginRequest? app)
    {
        var transaction = new Transaction(
            Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32)),
            Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(48)),
            Admin: admin,
            App: app);
        var protectedValue = protection.CreateProtector(TransactionPurpose).ToTimeLimitedDataProtector()
            .Protect(JsonSerializer.Serialize(transaction), TransactionLifetime);
        http.Response.Cookies.Append(TransactionCookieName, protectedValue, TransactionCookie(o));

        var query = new Dictionary<string, string?>
        {
            ["client_id"] = o.ClientId,
            ["redirect_uri"] = o.CallbackUri,
            ["response_type"] = "code",
            ["scope"] = o.RequestedScopes(transaction.Admin),
            ["state"] = transaction.State,
            ["code_challenge"] = Base64Url.EncodeToString(SHA256.HashData(Encoding.ASCII.GetBytes(transaction.Verifier))),
            ["code_challenge_method"] = "S256",
        };
        // "Entrar con otra cuenta": ZydroLogin vuelve a pedir Google aunque su sesión siga abierta.
        if (prompt == "login")
        {
            query["prompt"] = "login";
        }
        return Results.Redirect(QueryHelpers.AddQueryString(o.Endpoint("authorize").AbsoluteUri, query));
    }

    private static async Task<IResult> CallbackAsync(HttpContext http, IOptions<ZydroLoginOptions> options,
        IDataProtectionProvider protection, ZydroLoginClient login, LoginSessions sessions, DirectoryDb db,
        IOptions<ZydroSync.Api.Admin.AdminOptions> adminOptions, AppHandoffs handoffs, TimeProvider time, ILoggerFactory loggers,
        CancellationToken ct)
    {
        var o = options.Value;
        if (!o.Enabled)
        {
            return Results.NotFound();
        }
        var log = loggers.CreateLogger("ZydroSync.Login");
        var q = http.Request.Query;
        var home = "/";
        AppLoginRequest? app = null;

        // 1. state: la cookie de este navegador, de este intento, sin caducar y del mismo valor.
        if (!http.Request.Cookies.TryGetValue(TransactionCookieName, out var stored))
        {
            return Fail("invalid_state");
        }
        http.Response.Cookies.Delete(TransactionCookieName, TransactionCookie(o));
        Transaction transaction;
        try
        {
            transaction = JsonSerializer.Deserialize<Transaction>(
                protection.CreateProtector(TransactionPurpose).ToTimeLimitedDataProtector().Unprotect(stored))!;
        }
        catch (Exception e) when (e is CryptographicException or JsonException or FormatException)
        {
            return Fail("invalid_state");
        }
        if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(transaction.State), Encoding.UTF8.GetBytes(q["state"].ToString())))
        {
            return Fail("invalid_state");
        }
        if (transaction.Admin)
        {
            home = "/admin/";
        }
        // Desde aquí, los errores de un login de la app vuelven a la app (su redirect ya se validó).
        app = transaction.App;
        // 2. iss (RFC 9207): la respuesta viene de NUESTRO proveedor, no de otro que se haga pasar.
        if (q.ContainsKey("iss") && q["iss"].ToString() != o.IssuerUri.AbsoluteUri)
        {
            return Fail("invalid_issuer");
        }
        if (q.ContainsKey("error"))
        {
            return Fail(q["error"].ToString() is "access_denied" ? "access_denied" : "login_failed");
        }
        if (q["code"].ToString() is not { Length: > 0 and < 2048 } code)
        {
            return Fail("login_failed");
        }

        // 3. Canje en el backend, con secreto, callback exacto y code_verifier.
        LoginTokens tokens;
        try
        {
            tokens = await login.ExchangeCodeAsync(code, transaction.Verifier, ct);
        }
        catch (LoginProviderException e)
        {
            log.LogWarning("Canje del código rechazado: {Reason}", e.Message);
            return Fail(e.Failure == LoginFailure.Unavailable ? "unavailable" : "login_failed");
        }

        // 4. Perfil validado: sub, email verificado, audiencia y permiso propios.
        LoginUserInfo profile;
        try
        {
            profile = await login.UserInfoAsync(tokens.AccessToken, ct);
        }
        catch (LoginProviderException e)
        {
            await RevokeAsync(login, tokens, ct);
            return Fail(e.Failure == LoginFailure.Unavailable ? "unavailable" : "login_failed");
        }
        if (!profile.EmailVerified || string.IsNullOrEmpty(profile.Email)
            || !profile.Audiences.Contains(o.Audience) || !profile.Scopes.Contains(o.ReadScope))
        {
            await RevokeAsync(login, tokens, ct);
            return Fail("insufficient_scope");
        }

        // 5. Usuario de ZydroSync: por sub; la primera vez, por email verificado. Sin alta, no se entra.
        var user = await db.Users.FirstOrDefaultAsync(u => u.LoginSubject == profile.Subject, ct);
        if (user is null)
        {
            var email = profile.Email.Trim().ToLowerInvariant();
            user = await db.Users.FirstOrDefaultAsync(u => u.Email == email, ct);
            if (user is null)
            {
                await RevokeAsync(login, tokens, ct);
                log.LogInformation("Inicio de sesión de una identidad sin cuenta en ZydroSync");
                return Fail("no_account");
            }
            if (user.LoginSubject is not null)
            {
                // Ese email ya está vinculado a OTRA identidad: no se reasigna en silencio.
                await RevokeAsync(login, tokens, ct);
                log.LogWarning("El usuario {UserId} ya está vinculado a otra identidad de ZydroLogin", user.Id);
                return Fail("account_linked_elsewhere");
            }
            user.LoginSubject = profile.Subject;
            user.LoginLinkedAt = time.GetUtcNow();
            await db.SaveChangesAsync(ct);
            log.LogInformation("Usuario {UserId} vinculado a su identidad de ZydroLogin", user.Id);
        }

        // App: no hay sesión web. Los tokens de ZydroLogin no se necesitan (la app recibirá un
        // token de dispositivo de ZydroSync): se revocan. Vuelve a la app con un código de un
        // solo uso ligado a SU PKCE.
        if (app is not null)
        {
            await RevokeAsync(login, tokens, ct);
            var handoff = handoffs.Issue(user.Id, app);
            log.LogInformation("Login de la app con ZydroLogin para el usuario {UserId}", user.Id);
            return Results.Redirect(QueryHelpers.AddQueryString(app.RedirectUri, new Dictionary<string, string?>
            {
                ["code"] = handoff, ["state"] = app.State,
            }));
        }

        // Admin: el permiso concedido por ZydroLogin y el email en la lista privada del servidor.
        if (transaction.Admin && (!profile.Scopes.Contains(o.AdminScope) || !adminOptions.Value.IsAdminEmail(user.Email)))
        {
            await RevokeAsync(login, tokens, ct);
            log.LogWarning("Intento de entrar como administrador sin serlo: usuario {UserId}", user.Id);
            return Fail("not_admin");
        }

        // Si este navegador ya tenía una sesión (p. ej. la web normal antes de entrar al panel),
        // se cierra y se revocan sus tokens: no quedan sesiones huérfanas.
        if (http.Request.Cookies.TryGetValue(LoginSessions.CookieName, out var previous))
        {
            await sessions.SignOutAsync(previous, ct);
        }
        var cookie = await sessions.CreateAsync(user.Id, profile.Subject, tokens, transaction.Admin, ct);
        http.Response.Cookies.Append(LoginSessions.CookieName, cookie,
            SessionCookie(o, transaction.Admin ? LoginSessions.AdminLifetime : TimeSpan.FromDays(7)));
        log.LogInformation("Sesión {Kind} iniciada con ZydroLogin para el usuario {UserId}", transaction.Admin ? "de administración" : "web", user.Id);
        return Results.Redirect(home);

        IResult Fail(string reason) => app is null
            ? Results.Redirect($"{home}?login_error={reason}")
            : Results.Redirect(QueryHelpers.AddQueryString(app.RedirectUri, new Dictionary<string, string?>
            {
                ["error"] = reason, ["state"] = app.State,
            }));
    }

    private static async Task RevokeAsync(ZydroLoginClient login, LoginTokens tokens, CancellationToken ct)
    {
        if (tokens.RefreshToken is { } refresh)
        {
            await login.RevokeAsync(refresh, "refresh_token", ct);
        }
        await login.RevokeAsync(tokens.AccessToken, "access_token", ct);
    }

    private static async Task<IResult> LogoutAsync(HttpContext http, IOptions<ZydroLoginOptions> options, LoginSessions sessions,
        CancellationToken ct)
    {
        var o = options.Value;
        if (!o.Enabled)
        {
            return Results.NotFound();
        }
        // Con cookie, un POST de otro sitio podría cerrar tu sesión (CSRF): exige Origin propio.
        if (http.Request.Headers.Origin.ToString() != o.PublicOrigin)
        {
            return Results.Problem(statusCode: 403, detail: "Origen no permitido");
        }
        var revoked = false;
        if (http.Request.Cookies.TryGetValue(LoginSessions.CookieName, out var cookie))
        {
            revoked = await sessions.SignOutAsync(cookie, ct);
        }
        http.Response.Cookies.Delete(LoginSessions.CookieName, SessionCookie(o, TimeSpan.Zero));
        // La sesión de ZydroLogin (SSO, 8 h) sigue abierta: ZydroLogin no ofrece cerrarla.
        return Results.Ok(new { signedOut = true, tokensRevoked = revoked, ssoSessionStillOpen = true });
    }
}

public static class SessionCsrf
{
    /// <summary>
    /// Con la cookie de sesión, el navegador la envía sola: una petición que cambia algo
    /// (POST, PUT, PATCH, DELETE) solo se acepta si su Origin es el propio. SameSite=Lax ya
    /// frena casi todo; esto cierra el resto (subdominios, navegadores antiguos). Las
    /// peticiones con Authorization (tokens) no llevan cookie de sesión y no aplican.
    /// </summary>
    public static WebApplication UseSessionCsrfProtection(this WebApplication app)
    {
        app.Use(async (ctx, next) =>
        {
            var options = ctx.RequestServices.GetRequiredService<IOptions<ZydroLoginOptions>>().Value;
            if (options.Enabled && !HttpMethods.IsGet(ctx.Request.Method) && !HttpMethods.IsHead(ctx.Request.Method)
                && !HttpMethods.IsOptions(ctx.Request.Method)
                && ctx.Request.Cookies.ContainsKey(LoginSessions.CookieName)
                && string.IsNullOrEmpty(ctx.Request.Headers.Authorization)
                && ctx.Request.Headers.Origin.ToString() != options.PublicOrigin)
            {
                await Results.Problem(statusCode: 403, detail: "Origen no permitido").ExecuteAsync(ctx);
                return;
            }
            await next();
        });
        return app;
    }
}
