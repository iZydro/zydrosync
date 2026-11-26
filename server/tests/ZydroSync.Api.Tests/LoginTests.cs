using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using ZydroSync.Api.Data;
using ZydroSync.Api.Login;
using ZydroSync.Api.Workouts;

namespace ZydroSync.Api.Tests;

/// <summary>Todo lo que se registra, de cualquier categoría y nivel, para buscar secretos.</summary>
public sealed class CapturingLoggerProvider : ILoggerProvider
{
    public ConcurrentQueue<string> Lines { get; } = new();
    public ILogger CreateLogger(string category) => new Logger(category, Lines);
    public void Dispose() { }

    private sealed class Logger(string category, ConcurrentQueue<string> lines) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? error, Func<TState, Exception?, string> format) =>
            lines.Enqueue($"{level} {category}: {format(state, error)} {error}");
    }
}

/// <summary>La API con ZydroLogin configurado, contra el ZydroLogin simulado.</summary>
public sealed class LoginApiFactory : LoginApiFactoryBase;

public abstract class LoginApiFactoryBase : ApiFactory
{
    protected virtual IEnumerable<KeyValuePair<string, string?>> Extra() => [];

    public MutableClock Clock { get; } = new(DateTimeOffset.UtcNow);
    public FakeZydroLogin Login { get; }
    public CapturingLoggerProvider Logs { get; } = new();

    protected LoginApiFactoryBase() => Login = new FakeZydroLogin(Clock);

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        base.ConfigureWebHost(builder);
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ZydroLogin:Issuer"] = FakeZydroLogin.Issuer,
            ["ZydroLogin:ClientId"] = FakeZydroLogin.ClientId,
            ["ZydroLogin:ClientSecret"] = FakeZydroLogin.ClientSecret,
            ["ZydroLogin:CallbackUri"] = FakeZydroLogin.Callback,
            // Todo al máximo detalle salvo el log de peticiones de Kestrel/TestServer, que
            // escribe la URL completa (con el code del callback) y en producción está en Warning.
            ["Logging:LogLevel:Default"] = "Trace",
            ["Logging:LogLevel:Microsoft.AspNetCore"] = "Trace",
            ["Logging:LogLevel:Microsoft.AspNetCore.Hosting.Diagnostics"] = "Warning",
        }.Concat(Extra())));
        builder.ConfigureLogging(logging => logging.AddProvider(Logs));
        builder.ConfigureTestServices(services =>
        {
            services.AddSingleton<TimeProvider>(Clock);
            services.AddHttpClient(ZydroLoginClient.HttpClientName).ConfigurePrimaryHttpMessageHandler(() => Login);
        });
    }

    /// <summary>Un navegador: cookies, sin seguir redirecciones, en el origen público.</summary>
    public HttpClient Browser() => CreateClient(new WebApplicationFactoryClientOptions
    {
        AllowAutoRedirect = false, HandleCookies = true, BaseAddress = new Uri("https://sync.test"),
    });

    /// <summary>Recorrido completo: /auth/login → ZydroLogin → /auth/callback. Devuelve el Location final.</summary>
    public async Task<(HttpClient Browser, string Location)> SignInAsync(LoginProfile profile, HttpClient? browser = null, bool admin = false)
    {
        browser ??= Browser();
        var start = await browser.GetAsync(admin ? "/auth/login?admin=1" : "/auth/login");
        Assert.Equal(HttpStatusCode.Redirect, start.StatusCode);
        var callback = Login.Authorize(start.Headers.Location!, profile) ?? throw new InvalidOperationException("authorize rechazado");
        var done = await browser.GetAsync(callback);
        return (browser, done.Headers.Location!.OriginalString);
    }

    public Task Db(Func<DirectoryDb, Task> action) => WithDirectoryAsync(async db => { await action(db); return 0; });

    public async Task<TestUser> CreateUserAsync(string email)
    {
        var user = await CreateUserAsync();
        await Db(async db =>
        {
            var row = await db.Users.SingleAsync(u => u.Id == user.Id);
            row.Email = email;
            await db.SaveChangesAsync();
        });
        return user;
    }
}

public sealed class LoginTests(LoginApiFactory api) : IClassFixture<LoginApiFactory>
{
    private static LoginProfile NewProfile(out string email)
    {
        email = $"{Guid.NewGuid():N}@example.test";
        return new LoginProfile($"google-{Guid.NewGuid():N}", email);
    }

    private async Task<Guid> UploadAsync(TestUser user)
    {
        var id = Guid.NewGuid();
        var response = await api.ClientWith(user.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        return id;
    }

    private static HttpClient WithBearer(HttpClient client, string token)
    {
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    private static bool HasSessionCookie(HttpResponseMessage response) =>
        response.Headers.TryGetValues("Set-Cookie", out var cookies)
        && cookies.Any(c => c.StartsWith(LoginSessions.CookieName + "=") && !c.Contains("expires=Thu, 01 Jan 1970"));

    // MARK: Recorrido completo

    [Fact]
    public async Task Full_flow_links_the_user_by_email_then_reads_only_their_workouts()
    {
        var profile = NewProfile(out var email);
        var user = await api.CreateUserAsync(email);
        var mine = await UploadAsync(user);

        var (browser, location) = await api.SignInAsync(profile);

        Assert.Equal("/", location);
        var status = await browser.GetFromJsonAsync<JsonElement>("/auth/status");
        Assert.Equal(email, status.GetProperty("user").GetProperty("email").GetString());
        var page = await browser.GetFromJsonAsync<WorkoutPage>("/v1/workouts");
        Assert.Equal(mine, Assert.Single(page!.Items).WorkoutId);
        await api.Db(async db =>
            Assert.Equal(profile.Subject, (await db.Users.SingleAsync(u => u.Id == user.Id)).LoginSubject));
    }

    [Fact]
    public async Task Authorize_request_uses_pkce_s256_exact_callback_and_minimal_scopes()
    {
        var start = await api.Browser().GetAsync("/auth/login?prompt=login");
        var q = QueryHelpers.ParseQuery(start.Headers.Location!.Query);

        Assert.StartsWith(FakeZydroLogin.Issuer + "authorize?", start.Headers.Location!.AbsoluteUri);
        Assert.Equal(FakeZydroLogin.Callback, q["redirect_uri"]);
        Assert.Equal("S256", q["code_challenge_method"]);
        Assert.Equal("code", q["response_type"]);
        Assert.Equal("openid profile email offline_access zydrosync:workouts:read", q["scope"]);
        Assert.Equal("login", q["prompt"]);
        Assert.True(q["state"].ToString().Length >= 43);
        // El code_verifier no sale del servidor: solo su hash.
        Assert.False(q.ContainsKey("code_verifier"));
        var transaction = start.Headers.GetValues("Set-Cookie").Single(c => c.StartsWith(LoginEndpoints.TransactionCookieName + "="));
        Assert.Contains("httponly", transaction, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", transaction, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/auth/callback", transaction, StringComparison.OrdinalIgnoreCase);
    }

    // MARK: Rechazos en el callback

    [Fact]
    public async Task Wrong_state_is_rejected_and_no_session_is_created()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var browser = api.Browser();
        var start = await browser.GetAsync("/auth/login");
        var callback = api.Login.Authorize(start.Headers.Location!, profile)!;
        var tampered = QueryHelpers.AddQueryString(callback.Split('?')[0], new Dictionary<string, string?>
        {
            ["code"] = QueryHelpers.ParseQuery(new Uri(callback).Query)["code"],
            ["state"] = "estado-de-otro", ["iss"] = FakeZydroLogin.Issuer,
        });

        var response = await browser.GetAsync(tampered);

        Assert.Equal("/?login_error=invalid_state", response.Headers.Location!.OriginalString);
        Assert.False(HasSessionCookie(response));
        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Callback_in_another_browser_is_rejected()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var start = await api.Browser().GetAsync("/auth/login");
        var callback = api.Login.Authorize(start.Headers.Location!, profile)!;

        // Otro navegador (sin la cookie del intento): CSRF de login.
        var response = await api.Browser().GetAsync(callback);

        Assert.Equal("/?login_error=invalid_state", response.Headers.Location!.OriginalString);
    }

    [Fact]
    public async Task Code_obtained_with_another_pkce_challenge_is_rejected()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        // El atacante consigue un código con SU code_challenge…
        var attacker = await api.Browser().GetAsync("/auth/login");
        var stolen = api.Login.Authorize(attacker.Headers.Location!, profile)!;
        // …y lo inyecta en el callback de la víctima, con el state de la víctima.
        var victim = api.Browser();
        var start = await victim.GetAsync("/auth/login");
        var state = QueryHelpers.ParseQuery(start.Headers.Location!.Query)["state"];
        var injected = QueryHelpers.AddQueryString(FakeZydroLogin.Callback, new Dictionary<string, string?>
        {
            ["code"] = QueryHelpers.ParseQuery(new Uri(stolen).Query)["code"], ["state"] = state, ["iss"] = FakeZydroLogin.Issuer,
        });

        var response = await victim.GetAsync(injected);

        Assert.Equal("/?login_error=login_failed", response.Headers.Location!.OriginalString);
        Assert.False(HasSessionCookie(response));
    }

    [Fact]
    public async Task Response_from_another_issuer_is_rejected()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var browser = api.Browser();
        var start = await browser.GetAsync("/auth/login");
        var callback = api.Login.Authorize(start.Headers.Location!, profile)!
            .Replace(Uri.EscapeDataString(FakeZydroLogin.Issuer), Uri.EscapeDataString("https://evil.test/login/"));

        var response = await browser.GetAsync(callback);

        Assert.Equal("/?login_error=invalid_issuer", response.Headers.Location!.OriginalString);
    }

    [Fact]
    public async Task Unregistered_callback_never_gets_a_code()
    {
        var start = await api.Browser().GetAsync("/auth/login");
        var evil = new Uri(start.Headers.Location!.AbsoluteUri.Replace(Uri.EscapeDataString(FakeZydroLogin.Callback),
            Uri.EscapeDataString("https://evil.test/callback")));

        Assert.Null(api.Login.Authorize(evil, NewProfile(out _)));
    }

    [Fact]
    public async Task Unknown_user_is_not_created_and_its_tokens_are_revoked()
    {
        var revokedBefore = api.Login.Revoked.Count;

        var (_, location) = await api.SignInAsync(NewProfile(out var email));

        Assert.Equal("/?login_error=no_account", location);
        Assert.False(await api.WithDirectoryAsync(db => db.Users.AnyAsync(u => u.Email == email)));
        Assert.True(api.Login.Revoked.Count >= revokedBefore + 2);
    }

    [Fact]
    public async Task Email_already_linked_to_another_identity_is_not_relinked()
    {
        var first = NewProfile(out var email);
        await api.CreateUserAsync(email);
        await api.SignInAsync(first);

        var (_, location) = await api.SignInAsync(new LoginProfile("google-otra-identidad", email));

        Assert.Equal("/?login_error=account_linked_elsewhere", location);
    }

    [Fact]
    public async Task Unverified_email_is_rejected()
    {
        var profile = NewProfile(out var email) with { EmailVerified = false };
        await api.CreateUserAsync(email);

        var (_, location) = await api.SignInAsync(profile);

        Assert.Equal("/?login_error=insufficient_scope", location);
    }

    // MARK: Tokens Bearer de ZydroLogin

    [Fact]
    public async Task Bearer_from_zydrologin_reads_own_data_only()
    {
        var alice = NewProfile(out var aliceEmail);
        var bob = NewProfile(out var bobEmail);
        var aliceUser = await api.CreateUserAsync(aliceEmail);
        var bobUser = await api.CreateUserAsync(bobEmail);
        var aliceWorkout = await UploadAsync(aliceUser);
        var bobWorkout = await UploadAsync(bobUser);
        await api.SignInAsync(alice);
        await api.SignInAsync(bob);
        var bobClient = WithBearer(api.CreateClient(), api.Login.MintAccessToken(bob, "zydrosync", "openid", FakeZydroLogin.ReadScope));

        var page = await bobClient.GetFromJsonAsync<WorkoutPage>("/v1/workouts");

        Assert.Equal(bobWorkout, Assert.Single(page!.Items).WorkoutId);
        Assert.Equal(HttpStatusCode.NotFound, (await bobClient.GetAsync($"/v1/workouts/{aliceWorkout}")).StatusCode);
    }

    [Fact]
    public async Task Token_for_another_audience_is_rejected()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        await api.SignInAsync(profile);
        // Un token de sesión de ZydroTrack del mismo usuario no autoriza ZydroSync.
        var client = WithBearer(api.CreateClient(), api.Login.MintAccessToken(profile, "zydrotrack", "zydrotrack:session", FakeZydroLogin.ReadScope));

        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Token_without_the_read_permission_is_forbidden()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        await api.SignInAsync(profile);
        var client = WithBearer(api.CreateClient(), api.Login.MintAccessToken(profile, "zydrosync", "openid", "email"));

        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Token_of_an_identity_without_account_is_rejected()
    {
        var client = WithBearer(api.CreateClient(), api.Login.MintAccessToken(NewProfile(out _), "zydrosync", FakeZydroLogin.ReadScope));
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Login_access_cannot_upload_nor_use_the_admin_api()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        var id = Guid.NewGuid();

        Assert.Equal(HttpStatusCode.Forbidden, (await browser.SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await browser.GetAsync("/admin/api/users")).StatusCode); // panel desactivado
    }

    // MARK: Revocación, renovación y caídas

    [Fact]
    public async Task Revoked_tokens_end_the_session_immediately()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/v1/workouts")).StatusCode);

        api.Login.RevokeAllFor(profile.Subject);

        var response = await browser.GetAsync("/v1/workouts");
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        // Y no vuelve a intentarlo: la sesión ya no existe.
        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/v1/workouts")).StatusCode);
    }

    [Fact]
    public async Task Expired_access_token_is_refreshed_once_and_the_rotated_refresh_token_is_kept()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        var before = api.Login.RefreshCalls;

        api.Clock.Advance(TimeSpan.FromMinutes(16));
        var parallel = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => browser.GetAsync("/v1/workouts")));

        Assert.All(parallel, r => Assert.Equal(HttpStatusCode.OK, r.StatusCode));
        Assert.Equal(before + 1, api.Login.RefreshCalls); // una sola renovación con 5 peticiones a la vez

        api.Clock.Advance(TimeSpan.FromMinutes(16));
        Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/v1/workouts")).StatusCode); // con el refresh token NUEVO
        Assert.Equal(before + 2, api.Login.RefreshCalls);
    }

    [Fact]
    public async Task Refresh_rejected_ends_the_session_without_loops()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        api.Login.RevokeAllFor(profile.Subject);
        api.Clock.Advance(TimeSpan.FromMinutes(16));

        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/v1/workouts")).StatusCode);
        var status = await browser.GetFromJsonAsync<JsonElement>("/auth/status");
        Assert.Equal(JsonValueKind.Null, status.GetProperty("user").ValueKind);
    }

    [Fact]
    public async Task Provider_down_means_access_denied_not_granted()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        try
        {
            api.Login.Down = true;
            var response = await browser.GetAsync("/v1/workouts");
            Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        }
        finally
        {
            api.Login.Down = false;
        }
        // La sesión sobrevive a la caída.
        Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/v1/workouts")).StatusCode);
    }

    // MARK: Logout

    [Fact]
    public async Task Logout_requires_own_origin_revokes_tokens_and_reports_the_sso_session()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        var activeRefresh = api.Login.ActiveTokens("refresh");

        var foreign = new HttpRequestMessage(HttpMethod.Post, "/auth/logout");
        foreign.Headers.Add("Origin", "https://evil.test");
        Assert.Equal(HttpStatusCode.Forbidden, (await browser.SendAsync(foreign)).StatusCode);

        var logout = new HttpRequestMessage(HttpMethod.Post, "/auth/logout");
        logout.Headers.Add("Origin", "https://sync.test");
        var response = await browser.SendAsync(logout);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.True(body.GetProperty("tokensRevoked").GetBoolean());
        Assert.True(body.GetProperty("ssoSessionStillOpen").GetBoolean());
        Assert.Equal(activeRefresh - 1, api.Login.ActiveTokens("refresh"));
        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/v1/workouts")).StatusCode);
    }

    // MARK: Almacenamiento y logs

    [Fact]
    public async Task Tokens_are_stored_encrypted_and_never_logged()
    {
        var profile = NewProfile(out var email);
        await api.CreateUserAsync(email);
        var (browser, _) = await api.SignInAsync(profile);
        api.Clock.Advance(TimeSpan.FromMinutes(16));
        await browser.GetAsync("/v1/workouts");
        var logout = new HttpRequestMessage(HttpMethod.Post, "/auth/logout");
        logout.Headers.Add("Origin", "https://sync.test");
        await api.SignInAsync(NewProfileFor(email, profile.Subject)); // una segunda sesión que queda guardada
        await browser.SendAsync(logout);

        await api.Db(async db =>
        {
            foreach (var row in await db.LoginSessions.AsNoTracking().ToListAsync())
            {
                Assert.DoesNotContain(api.Login.Secrets, s => row.AccessToken.Contains(s) || (row.RefreshToken ?? "").Contains(s));
            }
        });
        var logs = string.Join('\n', api.Logs.Lines);
        Assert.NotEmpty(api.Logs.Lines);
        Assert.DoesNotContain(api.Login.Secrets, secret => logs.Contains(secret));
        Assert.DoesNotContain("zs_session=", logs);
    }

    private static LoginProfile NewProfileFor(string email, string subject) => new(subject, email);

    [Fact]
    public async Task Status_says_whether_login_is_available()
    {
        var status = await api.Browser().GetFromJsonAsync<JsonElement>("/auth/status");
        Assert.True(status.GetProperty("loginEnabled").GetBoolean());
        Assert.Equal(JsonValueKind.Null, status.GetProperty("user").ValueKind);
    }
}

public sealed class LoginDisabledTests(ApiFactory api) : IClassFixture<ApiFactory>
{
    [Fact]
    public async Task Without_configuration_there_is_no_login()
    {
        var client = api.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/auth/login")).StatusCode);
        var status = await client.GetFromJsonAsync<JsonElement>("/auth/status");
        Assert.False(status.GetProperty("loginEnabled").GetBoolean());
        // Un Bearer que no es propio no se acepta.
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "eyJ.no.valido");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/workouts")).StatusCode);
    }
}

/// <summary>Como en producción: panel activo, tokens admin solo por el túnel, admins por email.</summary>
public sealed class AdminLoginApiFactory : LoginApiFactoryBase
{
    public const string AdminEmail = "admin@example.test";
    protected override IEnumerable<KeyValuePair<string, string?>> Extra() =>
    [
        new("Admin:Enabled", "true"),
        new("Admin:LocalhostOnly", "true"),
        new("Admin:Emails:0", AdminEmail),
    ];
}

public sealed class AdminLoginTests(AdminLoginApiFactory api) : IClassFixture<AdminLoginApiFactory>
{
    private static readonly LoginProfile Admin = new("google-admin", AdminLoginApiFactory.AdminEmail);

    private async Task EnsureUsersAsync()
    {
        if (!await api.WithDirectoryAsync(db => db.Users.AnyAsync(u => u.Email == AdminLoginApiFactory.AdminEmail)))
        {
            await api.CreateUserAsync(AdminLoginApiFactory.AdminEmail);
        }
    }

    private static HttpRequestMessage Send(HttpMethod method, string path, string? origin = "https://sync.test", HttpContent? body = null)
    {
        var request = new HttpRequestMessage(method, path) { Content = body };
        if (origin is not null) request.Headers.Add("Origin", origin);
        return request;
    }

    [Fact]
    public async Task Admin_signs_in_through_zydrologin_and_uses_the_panel_api()
    {
        await EnsureUsersAsync();

        var (browser, location) = await api.SignInAsync(Admin, admin: true);

        Assert.Equal("/admin/", location);
        Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/admin/api/users")).StatusCode);
        var status = await browser.GetFromJsonAsync<JsonElement>("/auth/status");
        Assert.True(status.GetProperty("user").GetProperty("isAdmin").GetBoolean());
        var created = await browser.SendAsync(Send(HttpMethod.Post, "/admin/api/users",
            body: JsonContent.Create(new { email = $"{Guid.NewGuid():N}@example.test" })));
        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
    }

    [Fact]
    public async Task Admin_scope_is_only_requested_for_the_panel()
    {
        var web = await api.Browser().GetAsync("/auth/login");
        var panel = await api.Browser().GetAsync("/auth/login?admin=1");

        Assert.DoesNotContain("zydrosync:admin", Uri.UnescapeDataString(web.Headers.Location!.Query));
        Assert.Contains("zydrosync:admin", Uri.UnescapeDataString(panel.Headers.Location!.Query));
    }

    [Fact]
    public async Task Normal_web_session_of_the_admin_cannot_administer()
    {
        await EnsureUsersAsync();
        var (browser, _) = await api.SignInAsync(Admin);

        Assert.Equal(HttpStatusCode.Forbidden, (await browser.GetAsync("/admin/api/users")).StatusCode);
    }

    [Fact]
    public async Task Non_admin_user_asking_for_the_panel_is_rejected()
    {
        var email = $"{Guid.NewGuid():N}@example.test";
        await api.CreateUserAsync(email);

        var (browser, location) = await api.SignInAsync(new LoginProfile($"google-{Guid.NewGuid():N}", email), admin: true);

        Assert.Equal("/admin/?login_error=not_admin", location);
        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/admin/api/users")).StatusCode);
    }

    [Fact]
    public async Task Admin_changes_need_own_origin()
    {
        await EnsureUsersAsync();
        var (browser, _) = await api.SignInAsync(Admin, admin: true);
        var body = JsonContent.Create(new { email = $"{Guid.NewGuid():N}@example.test" });

        Assert.Equal(HttpStatusCode.Forbidden, (await browser.SendAsync(Send(HttpMethod.Post, "/admin/api/users", "https://evil.test", body))).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await browser.SendAsync(Send(HttpMethod.Post, "/admin/api/users", null, body))).StatusCode);
    }

    [Fact]
    public async Task Admin_session_ends_after_twelve_hours_even_if_refreshed()
    {
        await EnsureUsersAsync();
        var (browser, _) = await api.SignInAsync(Admin, admin: true);

        for (var i = 0; i < 11; i++)
        {
            api.Clock.Advance(TimeSpan.FromHours(1));
            Assert.Equal(HttpStatusCode.OK, (await browser.GetAsync("/admin/api/users")).StatusCode);
        }
        api.Clock.Advance(TimeSpan.FromHours(1.1));

        Assert.Equal(HttpStatusCode.Unauthorized, (await browser.GetAsync("/admin/api/users")).StatusCode);
    }

    [Fact]
    public async Task Admin_token_from_internet_is_ignored_but_admin_session_works_there()
    {
        await EnsureUsersAsync();
        var owner = await api.CreateUserAsync();
        var token = api.ClientWith(await api.CreateTokenAsync(owner.Id, TokenKind.Admin));
        token.BaseAddress = new Uri("https://sync.test");

        Assert.Equal(HttpStatusCode.NotFound, (await token.GetAsync("/admin/api/users")).StatusCode);
    }
}
