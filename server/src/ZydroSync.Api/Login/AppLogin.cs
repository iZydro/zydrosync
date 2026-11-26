using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Login;

/// <summary>Lo que pidió la app: su PKCE, su vuelta y su state. Viaja cifrado en la cookie del intento.</summary>
public sealed record AppLoginRequest(string Challenge, string RedirectUri, string State, string DeviceName);

/// <summary>
/// Login de la app iOS con ZydroLogin sin secreto en la app (RFC 8252 + PKCE, con ZydroSync
/// de intermediario):
///  1. La app abre GET /auth/app/start?redirect_uri=zydrosync://auth&amp;code_challenge=…&amp;state=…
///     en un ASWebAuthenticationSession, con SU code_verifier generado en el iPhone.
///  2. ZydroSync hace el login web normal con ZydroLogin (cliente confidencial, usuarios
///     conocidos, vínculo por sub). Los tokens de ZydroLogin no salen del servidor.
///  3. Vuelve a zydrosync://auth?code=…&amp;state=… con un código de un solo uso, 2 min,
///     ligado al code_challenge de la app.
///  4. La app canjea POST /auth/app/token (code + code_verifier + redirect_uri) y recibe un
///     token de dispositivo zsd_ a su nombre. Aunque otra app interceptara la vuelta, sin el
///     code_verifier el código no le sirve.
/// </summary>
public static class AppLogin
{
    private static readonly Regex Challenge = new("^[A-Za-z0-9_-]{43}$", RegexOptions.Compiled);
    private static readonly Regex State = new("^[A-Za-z0-9._~-]{16,128}$", RegexOptions.Compiled);
    private static readonly Regex Verifier = new("^[A-Za-z0-9._~-]{43,128}$", RegexOptions.Compiled);

    public static IResult Start(HttpContext http, IOptions<ZydroLoginOptions> options, Microsoft.AspNetCore.DataProtection.IDataProtectionProvider protection,
        string? redirect_uri, string? code_challenge, string? code_challenge_method, string? state, string? device, string? prompt)
    {
        var o = options.Value;
        if (!o.Enabled)
        {
            return Results.NotFound();
        }
        // Nada de esto se usa para redirigir hasta estar validado: un redirect_uri ajeno no recibe nada.
        if (redirect_uri != o.AppRedirectUri)
        {
            return Results.Problem(statusCode: 400, detail: "redirect_uri no registrado");
        }
        if (code_challenge_method != "S256" || code_challenge is null || !Challenge.IsMatch(code_challenge))
        {
            return Results.Problem(statusCode: 400, detail: "Se necesita PKCE S256 (code_challenge de 43 caracteres)");
        }
        if (state is null || !State.IsMatch(state))
        {
            return Results.Problem(statusCode: 400, detail: "state no válido");
        }
        var name = new string((device ?? "iPhone").Where(c => !char.IsControl(c)).Take(60).ToArray()).Trim();
        var app = new AppLoginRequest(code_challenge, redirect_uri, state, name.Length == 0 ? "iPhone" : name);
        return LoginEndpoints.StartAuthorize(http, o, protection, prompt, admin: false, app);
    }

    public static async Task<IResult> RedeemAsync(HttpContext http, IOptions<ZydroLoginOptions> options, AppHandoffs handoffs,
        DirectoryDb db, TokenService tokens, ILoggerFactory loggers, CancellationToken ct)
    {
        var o = options.Value;
        if (!o.Enabled)
        {
            return Results.NotFound();
        }
        if (!http.Request.HasFormContentType)
        {
            return Results.Problem(statusCode: 415, detail: "application/x-www-form-urlencoded");
        }
        var form = await http.Request.ReadFormAsync(ct);
        string code = form["code"].ToString(), verifier = form["code_verifier"].ToString(), redirect = form["redirect_uri"].ToString();
        if (!Verifier.IsMatch(verifier))
        {
            return InvalidGrant();
        }
        var grant = handoffs.Redeem(code, verifier, redirect);
        var user = grant is null ? null : await db.Users.AsNoTracking().FirstOrDefaultAsync(u => u.Id == grant.UserId, ct);
        if (grant is null || user is null)
        {
            return InvalidGrant();
        }
        var (token, secret) = await tokens.CreateAsync(user.Id, TokenKind.Device, $"{grant.DeviceName} (ZydroLogin)", ct);
        loggers.CreateLogger("ZydroSync.Login").LogInformation("Token de dispositivo {TokenId} creado por login de la app para el usuario {UserId}", token.Id, user.Id);
        return Results.Ok(new
        {
            token = secret,
            tokenId = token.Id,
            email = user.Email,
            uploadUrl = o.PublicOrigin + "/v1/workouts",
        });

        static IResult InvalidGrant() => Results.Json(new { error = "invalid_grant" }, statusCode: 400);
    }
}

/// <summary>
/// Códigos de un solo uso para la vuelta a la app. En memoria (una sola instancia; si el
/// servidor se reinicia en esos 2 minutos, se vuelve a entrar). Se guarda su SHA-256.
/// </summary>
public sealed class AppHandoffs(TimeProvider time)
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(2);

    public sealed record Grant(Guid UserId, string Challenge, string RedirectUri, string DeviceName, DateTimeOffset ExpiresAt);

    private readonly ConcurrentDictionary<string, Grant> _grants = new();

    public string Issue(Guid userId, AppLoginRequest app)
    {
        var now = time.GetUtcNow();
        foreach (var (key, old) in _grants)
        {
            if (old.ExpiresAt <= now) _grants.TryRemove(key, out _);
        }
        var code = Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));
        _grants[Key(code)] = new Grant(userId, app.Challenge, app.RedirectUri, app.DeviceName, now + Lifetime);
        return code;
    }

    /// <summary>Un solo intento: el código se consume aunque el verifier no coincida.</summary>
    public Grant? Redeem(string code, string verifier, string redirectUri)
    {
        if (code.Length is 0 or > 100 || !_grants.TryRemove(Key(code), out var grant))
        {
            return null;
        }
        var challenge = Base64Url.EncodeToString(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var ok = grant.ExpiresAt > time.GetUtcNow() && grant.RedirectUri == redirectUri
            && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(challenge), Encoding.ASCII.GetBytes(grant.Challenge));
        return ok ? grant : null;
    }

    private static string Key(string code) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(code)));
}
