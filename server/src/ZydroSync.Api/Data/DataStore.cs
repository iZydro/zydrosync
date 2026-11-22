using System.Collections.Concurrent;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace ZydroSync.Api.Data;

public sealed class StorageOptions
{
    /// <summary>Relativo a la raíz de contenido, o absoluto (en producción, un volumen: /data).</summary>
    public string DataDirectory { get; set; } = "data";
}

/// <summary>
/// Disposición en disco:
///   &lt;DataDirectory&gt;/directory.db          usuarios y tokens
///   &lt;DataDirectory&gt;/users/&lt;userId&gt;.db     entrenamientos de cada usuario
///
/// Un fichero por usuario: borrar un usuario es borrar su fichero (RGPD art. 17), exportar
/// sus datos es entregarle el fichero, y las copias y restauraciones son por usuario.
///
/// Singleton: lleva la cuenta de qué ficheros ya están migrados en este proceso y un candado
/// de escritura por usuario (SQLite admite un solo escritor por fichero; serializar en el
/// proceso evita esperas por SQLITE_BUSY y hace seguro el cálculo del siguiente seq).
/// Vale para UNA instancia del servidor, que es el despliegue previsto.
/// </summary>
public sealed class DataStore(IOptions<StorageOptions> options, IHostEnvironment environment)
{
    private readonly ConcurrentDictionary<Guid, Lazy<Task>> _ready = new();
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _writeLocks = new();

    public string DataDirectory { get; } = Path.GetFullPath(options.Value.DataDirectory, environment.ContentRootPath);
    public string DirectoryDbPath => Path.Combine(DataDirectory, "directory.db");
    public string UserDbPath(Guid userId) => Path.Combine(DataDirectory, "users", $"{userId:N}.db");
    public bool UserDbExists(Guid userId) => File.Exists(UserDbPath(userId));

    public static string ConnectionString(string path) =>
        new SqliteConnectionStringBuilder { DataSource = path, Pooling = true, ForeignKeys = true }.ToString();

    /// <summary>Crea el directorio de datos, migra directory.db y activa WAL. Al arrancar.</summary>
    public async Task InitializeDirectoryAsync(DirectoryDb db, CancellationToken ct = default)
    {
        Directory.CreateDirectory(Path.Combine(DataDirectory, "users"));
        await db.Database.MigrateAsync(ct);
        await EnableWalAsync(db, ct);
    }

    /// <summary>
    /// Abre (y la primera vez crea y migra) el fichero del usuario. Quien llama hace Dispose.
    /// </summary>
    public async Task<UserDb> OpenUserAsync(Guid userId, CancellationToken ct)
    {
        var ready = _ready.GetOrAdd(userId, id => new Lazy<Task>(() => InitializeUserAsync(id)));
        try
        {
            await ready.Value.WaitAsync(ct);
        }
        catch
        {
            _ready.TryRemove(new KeyValuePair<Guid, Lazy<Task>>(userId, ready));
            throw;
        }
        return CreateUserDb(userId);
    }

    public SemaphoreSlim WriteLock(Guid userId) => _writeLocks.GetOrAdd(userId, _ => new SemaphoreSlim(1, 1));

    /// <summary>Borra el fichero del usuario (y sus -wal/-shm). Irreversible.</summary>
    public async Task DeleteUserFilesAsync(Guid userId)
    {
        var gate = WriteLock(userId);
        await gate.WaitAsync();
        try
        {
            _ready.TryRemove(userId, out _);
            // Las conexiones en el pool mantienen el fichero abierto.
            SqliteConnection.ClearAllPools();
            var path = UserDbPath(userId);
            foreach (var file in new[] { path, path + "-wal", path + "-shm" })
            {
                File.Delete(file);
            }
        }
        finally
        {
            gate.Release();
        }
    }

    private UserDb CreateUserDb(Guid userId) =>
        new(new DbContextOptionsBuilder<UserDb>().UseSqlite(ConnectionString(UserDbPath(userId))).Options);

    private async Task InitializeUserAsync(Guid userId)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(UserDbPath(userId))!);
        await using var db = CreateUserDb(userId);
        await db.Database.MigrateAsync();
        await EnableWalAsync(db, CancellationToken.None);
    }

    /// <summary>WAL: lecturas sin bloquear la escritura. Es persistente en el fichero.</summary>
    private static Task EnableWalAsync(DbContext db, CancellationToken ct) =>
        db.Database.ExecuteSqlRawAsync("PRAGMA journal_mode=WAL;", ct);
}

/// <summary>Altas y bajas que tocan el directorio y los ficheros a la vez.</summary>
public sealed class AccountService(DirectoryDb directory, DataStore store)
{
    /// <summary>Borra el usuario, sus tokens y su fichero de datos (RGPD art. 17).</summary>
    public async Task<bool> DeleteUserAsync(Guid userId, CancellationToken ct)
    {
        await directory.ApiTokens.Where(t => t.UserId == userId).ExecuteDeleteAsync(ct);
        var deleted = await directory.Users.Where(u => u.Id == userId).ExecuteDeleteAsync(ct);
        await store.DeleteUserFilesAsync(userId);
        return deleted == 1;
    }
}
