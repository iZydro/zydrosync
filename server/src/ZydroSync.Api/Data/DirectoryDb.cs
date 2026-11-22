using Microsoft.EntityFrameworkCore;

namespace ZydroSync.Api.Data;

public enum TokenKind
{
    /// <summary>App iOS: sube entrenamientos y puede leer los suyos.</summary>
    Device = 1,
    /// <summary>Importadores (ZydroTrack): solo leen los entrenamientos de su usuario.</summary>
    Integration = 2,
    /// <summary>Panel de administración (/admin): ve y borra datos de TODOS los usuarios.</summary>
    Admin = 3,
    /// <summary>Web «Mis carreras»: solo lectura, para pegarlo en un navegador sin riesgo de que suba o borre.</summary>
    Web = 4,
}

public sealed class User
{
    /// <summary>También es el nombre de su fichero de datos (users/&lt;id&gt;.db), nunca el email.</summary>
    public Guid Id { get; set; }
    /// <summary>Normalizado a minúsculas.</summary>
    public required string Email { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public List<ApiToken> Tokens { get; } = [];
}

public sealed class ApiToken
{
    public Guid Id { get; set; }
    public Guid UserId { get; set; }
    public User User { get; set; } = null!;
    public required string Name { get; set; }
    public TokenKind Kind { get; set; }
    /// <summary>SHA-256 del secreto. El secreto solo se muestra una vez, al crearlo.</summary>
    public required byte[] Hash { get; set; }
    /// <summary>Primeros caracteres del secreto, para reconocerlo en listados.</summary>
    public required string Prefix { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastUsedAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
}

/// <summary>
/// Base de datos central (directory.db): quién es quién. Cada petición la consulta para
/// saber a qué usuario pertenece el token y, por tanto, qué fichero de datos abrir.
/// </summary>
public sealed class DirectoryDb(DbContextOptions<DirectoryDb> options) : DbContext(options)
{
    public DbSet<User> Users => Set<User>();
    public DbSet<ApiToken> ApiTokens => Set<ApiToken>();

    protected override void ConfigureConventions(ModelConfigurationBuilder c) => c.UseUtcBinaryDates();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<User>(e =>
        {
            e.ToTable("users");
            e.Property(x => x.Email).HasMaxLength(320);
            e.HasIndex(x => x.Email).IsUnique();
        });

        b.Entity<ApiToken>(e =>
        {
            e.ToTable("api_tokens");
            e.Property(x => x.Name).HasMaxLength(100);
            e.Property(x => x.Prefix).HasMaxLength(16);
            e.Property(x => x.Kind).HasConversion<string>().HasMaxLength(20);
            e.HasIndex(x => x.Hash).IsUnique();
            e.HasOne(x => x.User).WithMany(u => u.Tokens).HasForeignKey(x => x.UserId).OnDelete(DeleteBehavior.Cascade);
        });
    }
}

public static class SqliteConventions
{
    /// <summary>
    /// SQLite no tiene tipo fecha y EF Core no sabe ordenar ni comparar DateTimeOffset guardados
    /// como texto. Se guardan como entero (ticks + offset). Como siempre se guardan en UTC, el
    /// orden numérico es el cronológico.
    /// </summary>
    public static void UseUtcBinaryDates(this ModelConfigurationBuilder c)
    {
        c.Properties<DateTimeOffset>().HaveConversion<Microsoft.EntityFrameworkCore.Storage.ValueConversion.DateTimeOffsetToBinaryConverter>();
    }
}
