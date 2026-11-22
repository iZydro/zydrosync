using System.Net.Http.Headers;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Tests;

/// <summary>
/// La API completa en memoria (TestServer) con ficheros SQLite reales en un directorio
/// temporal propio por clase de tests. Ficheros de verdad y no SQLite en memoria: el
/// fichero-por-usuario, las migraciones al abrir y el borrado de ficheros son justo lo que
/// hay que probar.
/// </summary>
public class ApiFactory : WebApplicationFactory<Program>, IAsyncLifetime
{
    public string DataDirectory { get; } = Path.Combine(Path.GetTempPath(), "zydrosync-tests", Guid.NewGuid().ToString("N"));

    protected virtual int RateLimitPerMinute => 10_000;
    protected virtual bool AdminEnabled => false;

    public Task InitializeAsync() => Task.CompletedTask;

    async Task IAsyncLifetime.DisposeAsync()
    {
        await base.DisposeAsync();
        SqliteConnection.ClearAllPools();
        if (Directory.Exists(DataDirectory))
        {
            Directory.Delete(DataDirectory, recursive: true);
        }
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        // ConfigureAppConfiguration se añade al final: gana a appsettings y a las variables de entorno.
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Storage:DataDirectory"] = DataDirectory,
            ["RateLimit:PerMinute"] = RateLimitPerMinute.ToString(),
            ["Admin:Enabled"] = AdminEnabled.ToString(),
        }));
    }

    public async Task<TestUser> CreateUserAsync()
    {
        await using var scope = Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<DirectoryDb>();
        var tokens = scope.ServiceProvider.GetRequiredService<TokenService>();
        var user = new User { Id = Guid.CreateVersion7(), Email = $"{Guid.NewGuid():N}@test.local", CreatedAt = DateTimeOffset.UtcNow };
        db.Users.Add(user);
        await db.SaveChangesAsync();
        var (deviceToken, device) = await tokens.CreateAsync(user.Id, TokenKind.Device, "iPhone", CancellationToken.None);
        var (_, integration) = await tokens.CreateAsync(user.Id, TokenKind.Integration, "ZydroTrack", CancellationToken.None);
        return new TestUser(user.Id, device, integration, deviceToken.Id);
    }

    public async Task<string> CreateTokenAsync(Guid userId, TokenKind kind)
    {
        await using var scope = Services.CreateAsyncScope();
        var (_, secret) = await scope.ServiceProvider.GetRequiredService<TokenService>()
            .CreateAsync(userId, kind, kind.ToString(), CancellationToken.None);
        return secret;
    }

    public HttpClient ClientWith(string? token)
    {
        var client = CreateClient();
        if (token is not null)
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }
        return client;
    }

    public DataStore Store => Services.GetRequiredService<DataStore>();

    /// <summary>El scope (y el DbContext) vive hasta que termina la tarea.</summary>
    public async Task<T> WithDirectoryAsync<T>(Func<DirectoryDb, Task<T>> action)
    {
        await using var scope = Services.CreateAsyncScope();
        return await action(scope.ServiceProvider.GetRequiredService<DirectoryDb>());
    }

    public async Task<T> WithUserDbAsync<T>(Guid userId, Func<UserDb, Task<T>> action)
    {
        await using var db = await Store.OpenUserAsync(userId, CancellationToken.None);
        return await action(db);
    }

    public async Task<T> WithServiceAsync<TService, T>(Func<TService, Task<T>> action) where TService : notnull
    {
        await using var scope = Services.CreateAsyncScope();
        return await action(scope.ServiceProvider.GetRequiredService<TService>());
    }
}

public sealed class RateLimitedApiFactory : ApiFactory
{
    protected override int RateLimitPerMinute => 2;
}

public sealed class AdminApiFactory : ApiFactory
{
    protected override bool AdminEnabled => true;
}

public sealed record TestUser(Guid Id, string DeviceToken, string IntegrationToken, Guid DeviceTokenId);
