using System.Globalization;
using Microsoft.Data.Sqlite;

namespace ZydroSync.Api.Data;

public sealed record BackupResult(string Directory, int Files, long Bytes, IReadOnlyList<string> Pruned);

/// <summary>
/// Copia consistente de todas las bases de datos con <c>VACUUM INTO</c>: funciona con el
/// servidor en marcha (lee una instantánea, sin bloquear las escrituras en WAL) y el
/// resultado es un fichero compacto, sin -wal, que se abre tal cual.
///
/// Cada copia va a &lt;raíz&gt;/&lt;yyyyMMdd-HHmmss&gt;/ con la misma disposición que el
/// directorio de datos; restaurar es copiar esos ficheros con el servidor parado.
/// Se escribe primero en una carpeta ".partial" y se renombra al terminar: una copia
/// interrumpida nunca cuenta como buena ni desplaza a las anteriores.
/// </summary>
public static class Backup
{
    private const string StampFormat = "yyyyMMdd-HHmmss";
    private const string PartialSuffix = ".partial";

    public static async Task<BackupResult> CreateAsync(DataStore store, string root, DateTimeOffset now, int keep,
        CancellationToken ct)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(keep, 1);
        var name = now.UtcDateTime.ToString(StampFormat, CultureInfo.InvariantCulture);
        var final = Path.Combine(root, name);
        var partial = final + PartialSuffix;
        if (Directory.Exists(final))
        {
            throw new IOException($"Ya existe una copia {final}");
        }
        if (Directory.Exists(partial))
        {
            Directory.Delete(partial, recursive: true);
        }
        Directory.CreateDirectory(Path.Combine(partial, "users"));

        var sources = new List<(string Source, string Target)> { (store.DirectoryDbPath, Path.Combine(partial, "directory.db")) };
        var usersDir = Path.Combine(store.DataDirectory, "users");
        if (Directory.Exists(usersDir))
        {
            sources.AddRange(Directory.EnumerateFiles(usersDir, "*.db")
                .Order(StringComparer.Ordinal)
                .Select(f => (f, Path.Combine(partial, "users", Path.GetFileName(f)))));
        }

        long bytes = 0;
        foreach (var (source, target) in sources)
        {
            await CopyAsync(source, target, ct);
            bytes += new FileInfo(target).Length;
        }
        Directory.Move(partial, final);

        return new BackupResult(final, sources.Count, bytes, Prune(root, keep));
    }

    private static async Task CopyAsync(string source, string target, CancellationToken ct)
    {
        // Pooling desactivado: que no quede ninguna conexión abierta sobre la copia ni el origen.
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                     { DataSource = source, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
        {
            await connection.OpenAsync(ct);
            await using var vacuum = connection.CreateCommand();
            vacuum.CommandText = "VACUUM INTO $target";
            vacuum.Parameters.AddWithValue("$target", target);
            await vacuum.ExecuteNonQueryAsync(ct);
        }

        // Una copia que no se puede leer no es una copia.
        await using var check = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = target, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        await check.OpenAsync(ct);
        await using var command = check.CreateCommand();
        command.CommandText = "PRAGMA quick_check";
        var result = (string?)await command.ExecuteScalarAsync(ct);
        if (result != "ok")
        {
            throw new InvalidDataException($"La copia de {Path.GetFileName(source)} no pasa quick_check: {result}");
        }
    }

    /// <summary>Conserva las <paramref name="keep"/> copias más recientes; borra el resto y las parciales.</summary>
    private static List<string> Prune(string root, int keep)
    {
        var pruned = new List<string>();
        var complete = new List<string>();
        foreach (var dir in Directory.EnumerateDirectories(root))
        {
            var name = Path.GetFileName(dir);
            if (name.EndsWith(PartialSuffix, StringComparison.Ordinal))
            {
                Directory.Delete(dir, recursive: true);
                pruned.Add(name);
            }
            else if (DateTime.TryParseExact(name, StampFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out _))
            {
                complete.Add(name);
            }
            // Cualquier otra carpeta no es nuestra: no se toca.
        }
        foreach (var name in complete.OrderDescending(StringComparer.Ordinal).Skip(keep))
        {
            Directory.Delete(Path.Combine(root, name), recursive: true);
            pruned.Add(name);
        }
        return pruned;
    }
}
