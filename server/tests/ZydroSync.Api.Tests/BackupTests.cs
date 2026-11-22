using System.Net;
using Microsoft.Data.Sqlite;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Tests;

public sealed class BackupTests(ApiFactory api) : IClassFixture<ApiFactory>, IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "zydrosync-backups", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    private static long Count(string dbPath, string table)
    {
        using var connection = new SqliteConnection($"Data Source={dbPath};Mode=ReadOnly;Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = $"SELECT COUNT(*) FROM {table}";
        return (long)command.ExecuteScalar()!;
    }

    [Fact]
    public async Task Copies_directory_and_every_user_file_with_the_server_running()
    {
        var runner = await api.CreateUserAsync();
        for (var i = 0; i < 2; i++)
        {
            var id = Guid.NewGuid();
            var response = await api.ClientWith(runner.DeviceToken).SendAsync(Payloads.PostGzip(id, Payloads.Valid(id)));
            Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        }

        var result = await Backup.CreateAsync(api.Store, _root, DateTimeOffset.UtcNow, keep: 14, CancellationToken.None);

        Assert.Equal(Path.Combine(_root, Path.GetFileName(result.Directory)), result.Directory);
        Assert.True(Count(Path.Combine(result.Directory, "directory.db"), "Users") >= 1);
        var userCopy = Path.Combine(result.Directory, "users", $"{runner.Id:N}.db");
        Assert.Equal(2, Count(userCopy, "Workouts"));
        // VACUUM INTO deja un fichero autónomo: sin -wal que acompañe a la copia.
        Assert.False(File.Exists(userCopy + "-wal"));
        Assert.DoesNotContain(Directory.EnumerateDirectories(_root), d => d.EndsWith(".partial"));
    }

    [Fact]
    public async Task Keeps_only_the_newest_copies_and_leaves_foreign_folders_alone()
    {
        await api.CreateUserAsync();
        var start = new DateTimeOffset(2026, 11, 1, 3, 30, 0, TimeSpan.Zero);
        Directory.CreateDirectory(Path.Combine(_root, "notas"));
        Directory.CreateDirectory(Path.Combine(_root, "20261101-000000.partial"));

        for (var day = 0; day < 4; day++)
        {
            await Backup.CreateAsync(api.Store, _root, start.AddDays(day), keep: 2, CancellationToken.None);
        }

        var names = Directory.EnumerateDirectories(_root).Select(Path.GetFileName).Order().ToList();
        Assert.Equal(["20261103-033000", "20261104-033000", "notas"], names);
    }
}
