using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.WebUtilities;

namespace ZydroSync.Api.Tests;

public sealed class MutableClock(DateTimeOffset start) : TimeProvider
{
    private DateTimeOffset _now = start;
    public override DateTimeOffset GetUtcNow() => _now;
    public void Advance(TimeSpan by) => _now += by;
}

public sealed record LoginProfile(string Subject, string Email, bool EmailVerified = true);

/// <summary>
/// ZydroLogin simulado, con las reglas del real (OpenIddict): códigos de un solo uso y 2 min,
/// PKCE S256 obligatorio, callback exacto, refresh tokens que rotan, revocación e introspección
/// autenticada. La parte del navegador (authorize + Google) la hace <see cref="Authorize"/>.
/// </summary>
public sealed class FakeZydroLogin(MutableClock clock) : HttpMessageHandler
{
    public const string Issuer = "https://login.test/login/";
    public const string ClientId = "zydrosync";
    public const string ClientSecret = "test-client-secret-0123456789abcdefghijklmnopqrstuvwxyz";
    public const string Callback = "https://sync.test/auth/callback";
    public const string ReadScope = "zydrosync:workouts:read";

    private sealed record Code(string Challenge, string RedirectUri, LoginProfile Profile, string[] Scopes, DateTimeOffset ExpiresAt);

    private sealed class Token
    {
        public required string Value { get; init; }
        public required string Kind { get; init; }
        public required LoginProfile Profile { get; init; }
        public required string Audience { get; init; }
        public required string[] Scopes { get; init; }
        public required DateTimeOffset ExpiresAt { get; init; }
        public bool Revoked { get; set; }
    }

    private readonly ConcurrentDictionary<string, Code> _codes = new();
    private readonly ConcurrentDictionary<string, Token> _tokens = new();

    /// <summary>Simula una caída: cualquier llamada falla por red.</summary>
    public bool Down { get; set; }
    public int RefreshCalls;
    public ConcurrentBag<string> Revoked { get; } = [];
    /// <summary>Todo lo secreto que ha emitido: el test de logs comprueba que nada de esto aparece.</summary>
    public ConcurrentBag<string> Secrets { get; } = [ClientSecret];

    /// <summary>
    /// El viaje del navegador: /authorize (con el login de Google ya hecho) → URL del callback
    /// con code, state e iss. Rechaza lo mismo que el real: cliente, callback no registrado,
    /// PKCE que no sea S256 o sin el permiso propio. En ese caso devuelve null.
    /// </summary>
    public string? Authorize(Uri authorizeUrl, LoginProfile profile)
    {
        var q = QueryHelpers.ParseQuery(authorizeUrl.Query);
        string Get(string key) => q.TryGetValue(key, out var v) ? v.ToString() : "";
        if (authorizeUrl.GetLeftPart(UriPartial.Path) != Issuer + "authorize" || Get("client_id") != ClientId
            || Get("redirect_uri") != Callback || Get("response_type") != "code"
            || Get("code_challenge_method") != "S256" || Get("code_challenge").Length < 43
            || !Get("scope").Split(' ').Contains(ReadScope))
        {
            return null;
        }
        var code = Random();
        _codes[code] = new Code(Get("code_challenge"), Get("redirect_uri"), profile, Get("scope").Split(' '), clock.GetUtcNow().AddMinutes(2));
        Secrets.Add(code);
        return QueryHelpers.AddQueryString(Get("redirect_uri"), new Dictionary<string, string?>
        {
            ["code"] = code, ["state"] = Get("state"), ["iss"] = Issuer,
        });
    }

    /// <summary>Un access token emitido directamente (para probar Bearer con otras audiencias o permisos).</summary>
    public string MintAccessToken(LoginProfile profile, string audience, params string[] scopes) =>
        Issue("access", profile, audience, scopes, TimeSpan.FromMinutes(15));

    public void RevokeAllFor(string subject)
    {
        foreach (var t in _tokens.Values.Where(t => t.Profile.Subject == subject))
        {
            t.Revoked = true;
        }
    }

    public int ActiveTokens(string kind) => _tokens.Values.Count(t => t.Kind == kind && !t.Revoked && t.ExpiresAt > clock.GetUtcNow());

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        if (Down)
        {
            throw new HttpRequestException("ZydroLogin simulado caído");
        }
        var path = request.RequestUri!.AbsolutePath;
        var form = request.Content is null ? new Dictionary<string, string>()
            : QueryHelpers.ParseQuery(await request.Content.ReadAsStringAsync(ct)).ToDictionary(p => p.Key, p => p.Value.ToString());
        string Form(string key) => form.TryGetValue(key, out var v) ? v : "";
        bool ClientOk() => Form("client_id") == ClientId && Form("client_secret") == ClientSecret;

        switch (path)
        {
            case "/login/token":
                if (!ClientOk()) return Json(HttpStatusCode.Unauthorized, new { error = "invalid_client" });
                return Form("grant_type") switch
                {
                    "authorization_code" => ExchangeCode(Form("code"), Form("redirect_uri"), Form("code_verifier")),
                    "refresh_token" => Refresh(Form("refresh_token")),
                    _ => Json(HttpStatusCode.BadRequest, new { error = "unsupported_grant_type" }),
                };

            case "/login/userinfo":
                var bearer = request.Headers.Authorization?.Parameter ?? "";
                if (!_tokens.TryGetValue(bearer, out var access) || !IsActive(access, "access")) return new HttpResponseMessage(HttpStatusCode.Unauthorized);
                return Json(HttpStatusCode.OK, new
                {
                    sub = access.Profile.Subject, email = access.Profile.Email, email_verified = access.Profile.EmailVerified,
                    name = "Test", aud = new[] { access.Audience }, scope = string.Join(' ', access.Scopes),
                });

            case "/login/introspect":
                if (!ClientOk()) return Json(HttpStatusCode.Unauthorized, new { error = "invalid_client" });
                // Para probar NUESTRAS comprobaciones, responde active=true también para otras
                // audiencias (el real ya las rechazaría: así hay dos capas).
                if (!_tokens.TryGetValue(Form("token"), out var t) || !IsActive(t, t.Kind)) return Json(HttpStatusCode.OK, new { active = false });
                return Json(HttpStatusCode.OK, new
                {
                    active = true, iss = Issuer, sub = t.Profile.Subject, aud = t.Audience, scope = string.Join(' ', t.Scopes),
                    exp = t.ExpiresAt.ToUnixTimeSeconds(), token_usage = t.Kind == "access" ? "access_token" : "refresh_token",
                    client_id = ClientId,
                });

            case "/login/revoke":
                if (!ClientOk()) return Json(HttpStatusCode.Unauthorized, new { error = "invalid_client" });
                if (_tokens.TryGetValue(Form("token"), out var r))
                {
                    r.Revoked = true;
                    Revoked.Add(r.Kind);
                }
                return new HttpResponseMessage(HttpStatusCode.OK);

            default:
                return new HttpResponseMessage(HttpStatusCode.NotFound);
        }
    }

    private HttpResponseMessage ExchangeCode(string code, string redirectUri, string verifier)
    {
        // Un solo uso: se consume aunque luego falle la comprobación.
        if (!_codes.TryRemove(code, out var c) || c.ExpiresAt <= clock.GetUtcNow() || c.RedirectUri != redirectUri
            || Base64Url.EncodeToString(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))) != c.Challenge)
        {
            return Json(HttpStatusCode.BadRequest, new { error = "invalid_grant" });
        }
        return Tokens(c.Profile, c.Scopes);
    }

    private HttpResponseMessage Refresh(string refreshToken)
    {
        Interlocked.Increment(ref RefreshCalls);
        if (!_tokens.TryGetValue(refreshToken, out var t) || !IsActive(t, "refresh"))
        {
            return Json(HttpStatusCode.BadRequest, new { error = "invalid_grant" });
        }
        t.Revoked = true; // rotación: el anterior deja de valer
        return Tokens(t.Profile, t.Scopes);
    }

    private HttpResponseMessage Tokens(LoginProfile profile, string[] scopes)
    {
        var access = Issue("access", profile, "zydrosync", scopes, TimeSpan.FromMinutes(15));
        var refresh = scopes.Contains("offline_access") ? Issue("refresh", profile, "zydrosync", scopes, TimeSpan.FromDays(7)) : null;
        return Json(HttpStatusCode.OK, new
        {
            access_token = access, token_type = "Bearer", expires_in = 900, refresh_token = refresh,
            scope = string.Join(' ', scopes), id_token = "fake.id.token",
        });
    }

    private string Issue(string kind, LoginProfile profile, string audience, string[] scopes, TimeSpan lifetime)
    {
        var value = (kind == "access" ? "eyJ" : "rt_") + Random();
        _tokens[value] = new Token
        {
            Value = value, Kind = kind, Profile = profile, Audience = audience, Scopes = scopes,
            ExpiresAt = clock.GetUtcNow() + lifetime,
        };
        Secrets.Add(value);
        return value;
    }

    private bool IsActive(Token t, string kind) => t.Kind == kind && !t.Revoked && t.ExpiresAt > clock.GetUtcNow();

    private static string Random() => Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));

    private static HttpResponseMessage Json(HttpStatusCode status, object body) =>
        new(status) { Content = JsonContent.Create(body) };
}
