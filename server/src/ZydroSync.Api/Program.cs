using System.Threading.RateLimiting;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using ZydroSync.Api.Admin;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Cli;
using ZydroSync.Api.Data;
using ZydroSync.Api.Login;
using ZydroSync.Api.Web;
using ZydroSync.Api.Workouts;

// El mismo ejecutable sirve la API o ejecuta un comando de administración (ver AdminCli).
var isCli = args.Length > 0 && AdminCli.IsCommand(args[0]);
var builder = WebApplication.CreateBuilder(isCli ? [] : args);
if (isCli)
{
    // En la CLI, la salida estándar es solo el resultado del comando (redirigible a un
    // fichero). Los avisos van a stderr, y los mensajes informativos se silencian; el nivel
    // se fuerza por configuración porque la de appsettings tiene prioridad sobre SetMinimumLevel.
    builder.Configuration["Logging:LogLevel:Default"] = "Warning";
    builder.Services.Configure<Microsoft.Extensions.Logging.Console.ConsoleLoggerOptions>(
        o => o.LogToStandardErrorThreshold = LogLevel.Trace);
}

builder.Services.Configure<StorageOptions>(builder.Configuration.GetSection("Storage"));
builder.Services.AddSingleton<DataStore>();
builder.Services.AddScoped<AccountService>();
// La ruta se resuelve al crear el DbContext, no aquí: así los tests pueden cambiar
// Storage:DataDirectory con WebApplicationFactory sin depender del orden de carga.
builder.Services.AddDbContext<DirectoryDb>((sp, options) =>
    options.UseSqlite(DataStore.ConnectionString(sp.GetRequiredService<DataStore>().DirectoryDbPath)));
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddScoped<TokenService>();
builder.Services.Configure<IngestOptions>(builder.Configuration.GetSection("Ingest"));
builder.Services.Configure<AdminOptions>(builder.Configuration.GetSection("Admin"));

// ZydroLogin: inicio de sesión web y tokens de ZydroLogin (ver Login/). Sin ClientId/Secret
// configurados, no existe y solo valen los tokens propios.
builder.Services.Configure<ZydroLoginOptions>(builder.Configuration.GetSection("ZydroLogin"));
builder.Services.AddHttpClient(ZydroLoginClient.HttpClientName, c => c.Timeout = TimeSpan.FromSeconds(10));
builder.Services.AddScoped<ZydroLoginClient>();
builder.Services.AddScoped<LoginSessions>();
// Data Protection cifra los tokens de las sesiones y la cookie temporal del login. Las claves
// van al volumen de datos (persisten entre despliegues); la ruta se resuelve al usarlas, como
// la de las bases de datos, para que los tests puedan cambiarla.
builder.Services.AddDataProtection().SetApplicationName("ZydroSync");
builder.Services.AddOptions<Microsoft.AspNetCore.DataProtection.KeyManagement.KeyManagementOptions>()
    .Configure<DataStore, ILoggerFactory>((o, store, loggers) => o.XmlRepository =
        new Microsoft.AspNetCore.DataProtection.Repositories.FileSystemXmlRepository(
            new DirectoryInfo(Path.Combine(store.DataDirectory, "keys")), loggers));

// Un esquema que elige: tokens propios (zsd_, zsi_, zsw_, zsa_) → BearerTokenHandler; otro
// Bearer o la cookie de sesión → ZydroLogin (introspección).
const string AutoScheme = "Auto";
builder.Services.AddAuthentication(AutoScheme)
    .AddPolicyScheme(AutoScheme, null, o => o.ForwardDefaultSelector = ctx =>
    {
        string header = ctx.Request.Headers.Authorization.ToString();
        if (TokenService.IsOwnToken(header)) return BearerTokenHandler.SchemeName;
        if (header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            || ctx.Request.Cookies.ContainsKey(LoginSessions.CookieName)) return ZydroLoginHandler.SchemeName;
        return BearerTokenHandler.SchemeName;
    })
    .AddScheme<AuthenticationSchemeOptions, BearerTokenHandler>(BearerTokenHandler.SchemeName, null)
    .AddScheme<AuthenticationSchemeOptions, ZydroLoginHandler>(ZydroLoginHandler.SchemeName, null);
builder.Services.AddAuthorizationBuilder()
    .AddPolicy(Policies.Device, p => p.RequireClaim(BearerTokenHandler.KindClaim, nameof(TokenKind.Device)))
    .AddPolicy(Policies.Integration, p => p.RequireClaim(BearerTokenHandler.KindClaim, nameof(TokenKind.Integration)))
    // Token admin (solo por el túnel, ver UseAdminLocalhostOnly) o sesión de administrador de ZydroLogin.
    .AddPolicy(Policies.Admin, p => p.RequireAssertion(ctx =>
        ctx.User.HasClaim(BearerTokenHandler.KindClaim, nameof(TokenKind.Admin))
        || ctx.User.HasClaim(ZydroLoginHandler.AdminClaim, "true")))
    .AddPolicy(Policies.Reader, p => p.RequireAssertion(ctx =>
        ctx.User.HasClaim(c => c.Type == BearerTokenHandler.KindClaim
            && c.Value is nameof(TokenKind.Device) or nameof(TokenKind.Integration) or nameof(TokenKind.Web))
        // Con ZydroLogin, además, el permiso concreto en el scope del token.
        || (ctx.User.HasClaim(BearerTokenHandler.KindClaim, "Login")
            && ctx.User.HasClaim(ZydroLoginHandler.ScopeClaim, ctx.Resource is HttpContext http
                ? http.RequestServices.GetRequiredService<Microsoft.Extensions.Options.IOptions<ZydroLoginOptions>>().Value.ReadScope
                : "zydrosync:workouts:read"))));

builder.Services.AddProblemDetails();

// Límite por token (no por IP: varios usuarios pueden compartir IP, p. ej. tras un CGNAT).
// 429 + Retry-After, que la app ya respeta.
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.OnRejected = (context, _) =>
    {
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter = ((int)Math.Ceiling(retryAfter.TotalSeconds)).ToString();
        }
        return ValueTask.CompletedTask;
    };
    options.AddPolicy(WorkoutIngest.RateLimitPolicy, http =>
    {
        var perMinute = http.RequestServices.GetRequiredService<IConfiguration>().GetValue("RateLimit:PerMinute", 120);
        var partition = http.User.FindFirst(BearerTokenHandler.TokenIdClaim)?.Value
            ?? http.Connection.RemoteIpAddress?.ToString() ?? "anonymous";
        return RateLimitPartition.GetFixedWindowLimiter(partition, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = perMinute,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0,
        });
    });
});

var app = builder.Build();

if (isCli)
{
    return await AdminCli.RunAsync(app.Services, args);
}

// Migrar el directorio al arrancar; los ficheros de usuario se migran al abrirlos (DataStore).
// Con una sola instancia es lo más simple y evita servir código nuevo sobre un esquema viejo.
await using (var scope = app.Services.CreateAsyncScope())
{
    await scope.ServiceProvider.GetRequiredService<DataStore>()
        .InitializeDirectoryAsync(scope.ServiceProvider.GetRequiredService<DirectoryDb>());
}

app.UseSecurityHeaders();
app.UseAdminLocalhostOnly();
app.UseSessionCsrfProtection();
app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

app.MapGet("/healthz", async (DirectoryDb db, CancellationToken ct) =>
    await db.Database.CanConnectAsync(ct) ? Results.Ok(new { status = "ok" }) : Results.StatusCode(503));
app.MapWorkoutIngest();
app.MapWorkoutRead();
app.MapLoginEndpoints();
app.MapAdminPanel();
app.MapStaticSites();

await app.RunAsync();
return 0;

// Para WebApplicationFactory<Program> en los tests.
public partial class Program;
