using Microsoft.EntityFrameworkCore;

namespace ZydroSync.Api.Data;

/// <summary>
/// Un entrenamiento tal cual lo envió la app, más columnas de resumen para listar.
/// El JSON se guarda comprimido y sin tocar: si mañana cambia el procesamiento (p. ej. la
/// ventana de la cadencia), se reprocesa desde aquí sin volver a pedírselo al iPhone.
/// </summary>
public sealed class Workout
{
    /// <summary>UUID de HealthKit. Clave de idempotencia (el fichero ya es de un solo usuario).</summary>
    public Guid WorkoutId { get; set; }
    /// <summary>
    /// Cursor del usuario, creciente: cambia al crear y al actualizar. El importador pide
    /// "lo que tenga seq &gt; el último que vi" y así ve también las actualizaciones.
    /// </summary>
    public long Seq { get; set; }
    public int SchemaVersion { get; set; }
    public required string Sport { get; set; }
    public DateTimeOffset StartDate { get; set; }
    public DateTimeOffset EndDate { get; set; }
    public double DurationSec { get; set; }
    public double? DistanceM { get; set; }
    public bool Indoor { get; set; }
    public required string SourceBundleId { get; set; }
    public string? SourceProductType { get; set; }
    public int RoutePoints { get; set; }
    public required byte[] PayloadGzip { get; set; }
    public required byte[] PayloadSha256 { get; set; }
    public int PayloadJsonBytes { get; set; }
    public DateTimeOffset ReceivedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}

/// <summary>Los datos de UN usuario: users/&lt;userId&gt;.db.</summary>
public sealed class UserDb(DbContextOptions<UserDb> options) : DbContext(options)
{
    public DbSet<Workout> Workouts => Set<Workout>();

    protected override void ConfigureConventions(ModelConfigurationBuilder c) => c.UseUtcBinaryDates();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Workout>(e =>
        {
            e.ToTable("workouts");
            e.HasKey(x => x.WorkoutId);
            e.Property(x => x.Sport).HasMaxLength(40);
            e.Property(x => x.SourceBundleId).HasMaxLength(200);
            e.Property(x => x.SourceProductType).HasMaxLength(40);
            e.HasIndex(x => x.Seq).IsUnique();
            e.HasIndex(x => x.StartDate);
        });
    }
}
