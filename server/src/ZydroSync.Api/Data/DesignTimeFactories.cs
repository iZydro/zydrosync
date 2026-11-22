using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace ZydroSync.Api.Data;

// Para `dotnet ef migrations add … -c DirectoryDb|UserDb`: crean el DbContext sin arrancar la
// aplicación. Generar una migración solo compara el modelo con el snapshot; no abre ficheros.

public sealed class DirectoryDbDesignTimeFactory : IDesignTimeDbContextFactory<DirectoryDb>
{
    public DirectoryDb CreateDbContext(string[] args) =>
        new(new DbContextOptionsBuilder<DirectoryDb>().UseSqlite("Data Source=design-directory.db").Options);
}

public sealed class UserDbDesignTimeFactory : IDesignTimeDbContextFactory<UserDb>
{
    public UserDb CreateDbContext(string[] args) =>
        new(new DbContextOptionsBuilder<UserDb>().UseSqlite("Data Source=design-user.db").Options);
}
