using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace ZydroSync.Api.Login;

/// <summary>
/// ZydroSync como cliente confidencial de ZydroLogin (OIDC, Authorization Code + PKCE S256).
/// Las credenciales vienen de configuración privada (variables de entorno en el servidor:
/// ZydroLogin__ClientId, ZydroLogin__ClientSecret, ZydroLogin__CallbackUri). Sin ellas, el
/// inicio de sesión con ZydroLogin no existe y todo sigue funcionando con tokens propios.
/// </summary>
public sealed class ZydroLoginOptions
{
    public string Issuer { get; set; } = "https://zydrotrack.isidrogilabert.com/login/";
    public string? ClientId { get; set; }
    public string? ClientSecret { get; set; }
    /// <summary>Exactamente el registrado en ZydroLogin, p. ej. https://sync.isidrogilabert.com/auth/callback.</summary>
    public string? CallbackUri { get; set; }
    public string Audience { get; set; } = "zydrosync";
    /// <summary>Permiso para leer los entrenamientos propios. Los permisos empiezan por la audiencia.</summary>
    public string ReadScope { get; set; } = "zydrosync:workouts:read";
    /// <summary>Solo se pide al entrar al panel de administración; además hace falta ser admin (Admin:Emails).</summary>
    public string AdminScope { get; set; } = "zydrosync:admin";

    public bool Enabled =>
        !string.IsNullOrWhiteSpace(ClientId) && !string.IsNullOrWhiteSpace(ClientSecret) && !string.IsNullOrWhiteSpace(CallbackUri);

    /// <summary>Lo que se pide al autorizar: identidad, renovación y los permisos propios mínimos.</summary>
    public string RequestedScopes(bool admin) =>
        $"openid profile email offline_access {ReadScope}" + (admin ? $" {AdminScope}" : "");

    public Uri IssuerUri => new(Issuer.TrimEnd('/') + "/");
    public Uri Endpoint(string path) => new(IssuerUri, path);

    /// <summary>Origen público de ZydroSync (para comprobar Origin en los POST con cookie).</summary>
    public string PublicOrigin => new Uri(CallbackUri!).GetLeftPart(UriPartial.Authority);
}

public sealed record LoginTokens(string AccessToken, string? RefreshToken, DateTimeOffset AccessTokenExpiresAt, TimeSpan? RefreshTokenLifetime);

public sealed record LoginUserInfo(string Subject, string? Email, bool EmailVerified, string? Name,
    IReadOnlyList<string> Audiences, IReadOnlyList<string> Scopes);

public sealed record Introspection(bool Active, string? Subject, string? Issuer, IReadOnlyList<string> Audiences,
    IReadOnlyList<string> Scopes, DateTimeOffset? ExpiresAt, string? TokenUsage);

public enum LoginFailure
{
    /// <summary>ZydroLogin dice que no: código usado o caducado, PKCE incorrecto, token revocado…</summary>
    Rejected,
    /// <summary>ZydroLogin no responde o responde algo inesperado. Se rechaza el acceso igualmente.</summary>
    Unavailable,
}

/// <summary>
/// El mensaje es un código fijo, nunca el cuerpo de la respuesta ni un token: las excepciones
/// pueden acabar en un log.
/// </summary>
public sealed class LoginProviderException(LoginFailure failure, string code) : Exception(code)
{
    public LoginFailure Failure { get; } = failure;
}

/// <summary>
/// Llamadas de servidor a servidor a ZydroLogin. Nunca registra tokens, códigos ni secretos:
/// los cuerpos van como formulario (no en la URL) y los errores se reducen a un código.
/// </summary>
public sealed class ZydroLoginClient(IHttpClientFactory factory, IOptions<ZydroLoginOptions> options, TimeProvider time)
{
    public const string HttpClientName = "zydrologin";
    private ZydroLoginOptions Options => options.Value;

    public Task<LoginTokens> ExchangeCodeAsync(string code, string codeVerifier, CancellationToken ct) =>
        TokenRequestAsync(new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = Options.CallbackUri!,
            ["code_verifier"] = codeVerifier,
        }, ct);

    /// <summary>El refresh token rota: la respuesta trae uno nuevo y el anterior deja de valer.</summary>
    public Task<LoginTokens> RefreshAsync(string refreshToken, CancellationToken ct) =>
        TokenRequestAsync(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
        }, ct);

    public async Task<LoginUserInfo> UserInfoAsync(string accessToken, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Options.Endpoint("userinfo"));
        request.Headers.Authorization = new("Bearer", accessToken);
        using var json = await SendAsync(request, "userinfo", ct);
        var root = json.RootElement;
        var subject = String(root, "sub");
        if (string.IsNullOrEmpty(subject))
        {
            throw new LoginProviderException(LoginFailure.Rejected, "userinfo_without_subject");
        }
        return new LoginUserInfo(subject, String(root, "email"),
            root.TryGetProperty("email_verified", out var verified) && verified.ValueKind == JsonValueKind.True,
            String(root, "name"), Strings(root, "aud"), SplitScopes(String(root, "scope")));
    }

    public async Task<Introspection> IntrospectAsync(string token, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Options.Endpoint("introspect"))
        {
            Content = WithClient(new Dictionary<string, string> { ["token"] = token, ["token_type_hint"] = "access_token" }),
        };
        using var json = await SendAsync(request, "introspect", ct);
        var root = json.RootElement;
        if (!root.TryGetProperty("active", out var active) || active.ValueKind != JsonValueKind.True)
        {
            return new Introspection(false, null, null, [], [], null, null);
        }
        DateTimeOffset? expires = root.TryGetProperty("exp", out var exp) && exp.TryGetInt64(out var seconds)
            ? DateTimeOffset.FromUnixTimeSeconds(seconds)
            : null;
        return new Introspection(true, String(root, "sub"), String(root, "iss"), Strings(root, "aud"),
            SplitScopes(String(root, "scope")), expires, String(root, "token_usage"));
    }

    /// <summary>Revocación (RFC 7009). Devuelve false si ZydroLogin no la confirmó.</summary>
    public async Task<bool> RevokeAsync(string token, string hint, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Options.Endpoint("revoke"))
        {
            Content = WithClient(new Dictionary<string, string> { ["token"] = token, ["token_type_hint"] = hint }),
        };
        try
        {
            using var response = await factory.CreateClient(HttpClientName).SendAsync(request, ct);
            return response.IsSuccessStatusCode;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return false;
        }
    }

    /// <summary>
    /// Comprobaciones de un access token para ZydroSync, además de active=true: emisor exacto,
    /// audiencia propia (así no vale un token de ZydroTrack), vigencia, `sub` y que sea un
    /// access token y no otro tipo. El permiso concreto lo exige cada política.
    /// </summary>
    public string? Validate(Introspection result)
    {
        if (!result.Active) return "inactive";
        if (!string.Equals(result.Issuer, Options.IssuerUri.AbsoluteUri, StringComparison.Ordinal)) return "issuer";
        if (!result.Audiences.Contains(Options.Audience, StringComparer.Ordinal)) return "audience";
        if (result.ExpiresAt is not { } exp || exp <= time.GetUtcNow()) return "expired";
        if (string.IsNullOrEmpty(result.Subject)) return "subject";
        if (result.TokenUsage is { } usage && usage != "access_token") return "token_usage";
        return null;
    }

    private async Task<LoginTokens> TokenRequestAsync(Dictionary<string, string> form, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Options.Endpoint("token")) { Content = WithClient(form) };
        using var json = await SendAsync(request, "token", ct);
        var root = json.RootElement;
        var access = String(root, "access_token");
        if (string.IsNullOrEmpty(access) || !string.Equals(String(root, "token_type"), "Bearer", StringComparison.OrdinalIgnoreCase))
        {
            throw new LoginProviderException(LoginFailure.Unavailable, "token_response_invalid");
        }
        var lifetime = root.TryGetProperty("expires_in", out var e) && e.TryGetInt32(out var s) ? s : 900;
        TimeSpan? refreshLifetime = root.TryGetProperty("refresh_token_expires_in", out var r) && r.TryGetInt32(out var rs)
            ? TimeSpan.FromSeconds(rs)
            : null;
        return new LoginTokens(access, String(root, "refresh_token"), time.GetUtcNow().AddSeconds(lifetime), refreshLifetime);
    }

    private FormUrlEncodedContent WithClient(Dictionary<string, string> form)
    {
        form["client_id"] = Options.ClientId!;
        form["client_secret"] = Options.ClientSecret!;
        return new FormUrlEncodedContent(form);
    }

    private async Task<JsonDocument> SendAsync(HttpRequestMessage request, string operation, CancellationToken ct)
    {
        HttpResponseMessage response;
        try
        {
            response = await factory.CreateClient(HttpClientName).SendAsync(request, ct);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            throw new LoginProviderException(LoginFailure.Unavailable, $"{operation}_unreachable");
        }
        using (response)
        {
            // 400/401/403: ZydroLogin rechaza (invalid_grant, invalid_client, token no válido).
            if (response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            {
                throw new LoginProviderException(LoginFailure.Rejected, $"{operation}_rejected");
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new LoginProviderException(LoginFailure.Unavailable, $"{operation}_status_{(int)response.StatusCode}");
            }
            try
            {
                return await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct);
            }
            catch (JsonException)
            {
                throw new LoginProviderException(LoginFailure.Unavailable, $"{operation}_invalid_json");
            }
        }
    }

    private static string? String(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>`aud` puede venir como cadena o como array.</summary>
    private static IReadOnlyList<string> Strings(JsonElement root, string name) =>
        !root.TryGetProperty(name, out var value) ? []
        : value.ValueKind == JsonValueKind.String ? [value.GetString()!]
        : value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().Where(v => v.ValueKind == JsonValueKind.String).Select(v => v.GetString()!).ToList()
        : [];

    private static IReadOnlyList<string> SplitScopes(string? scope) =>
        scope?.Split(' ', StringSplitOptions.RemoveEmptyEntries) ?? [];
}
