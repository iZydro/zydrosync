using Microsoft.EntityFrameworkCore;
using ZydroSync.Api.Auth;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Cli;

/// <summary>
/// Administración desde la línea de comandos, en el mismo ejecutable que la API: una sola
/// imagen que desplegar. En producción:
///   docker compose exec api dotnet ZydroSync.Api.dll users add yo@ejemplo.com
///
/// Es la etapa 1 del multiusuario: altas y tokens a mano. La etapa 2 (S4) añadirá el inicio
/// de sesión desde la app.
/// </summary>
public static class AdminCli
{
    private static readonly HashSet<string> Commands = ["users", "tokens", "migrate", "help"];

    public static bool IsCommand(string arg) => Commands.Contains(arg);

    public static async Task<int> RunAsync(IServiceProvider services, string[] args)
    {
        await using var scope = services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<DirectoryDb>();
        var store = scope.ServiceProvider.GetRequiredService<DataStore>();
        var accounts = scope.ServiceProvider.GetRequiredService<AccountService>();
        var tokens = scope.ServiceProvider.GetRequiredService<TokenService>();
        var time = scope.ServiceProvider.GetRequiredService<TimeProvider>();
        var ct = CancellationToken.None;

        if (args is not ["help"])
        {
            await store.InitializeDirectoryAsync(db, ct);
        }

        switch (args)
        {
            case ["migrate"]:
                Console.WriteLine($"Directorio migrado: {store.DirectoryDbPath}");
                Console.WriteLine("Los ficheros de usuario se migran al abrirlos.");
                return 0;

            case ["users", "add", var email]:
            {
                var user = new User { Id = Guid.CreateVersion7(), Email = Normalize(email), CreatedAt = time.GetUtcNow() };
                db.Users.Add(user);
                await db.SaveChangesAsync(ct);
                Console.WriteLine($"Usuario creado: {user.Email} ({user.Id})");
                return 0;
            }

            case ["users", "list"]:
                foreach (var u in await db.Users.OrderBy(u => u.Email).ToListAsync(ct))
                {
                    var count = 0;
                    if (store.UserDbExists(u.Id))
                    {
                        await using var userDb = await store.OpenUserAsync(u.Id, ct);
                        count = await userDb.Workouts.CountAsync(ct);
                    }
                    Console.WriteLine($"{u.Email,-40} {u.Id}  entrenos={count}");
                }
                return 0;

            case ["users", "delete", var email, "--yes"]:
            {
                // RGPD art. 17: borra el usuario, sus tokens y su fichero de datos.
                var user = await FindUserAsync(db, email, ct);
                if (user is null)
                {
                    return 1;
                }
                await accounts.DeleteUserAsync(user.Id, ct);
                Console.WriteLine("Usuario y todos sus datos borrados.");
                return 0;
            }

            case ["users", "delete", _]:
                Console.Error.WriteLine("Borra el usuario y TODOS sus datos, sin vuelta atrás. Repite con --yes.");
                return 2;

            case ["tokens", "create", var email, var kindText, .. var nameParts]:
            {
                if (!Enum.TryParse<TokenKind>(kindText, ignoreCase: true, out var kind))
                {
                    Console.Error.WriteLine("Tipo de token: device o integration");
                    return 2;
                }
                var user = await FindUserAsync(db, email, ct);
                if (user is null)
                {
                    return 1;
                }
                var name = nameParts.Length > 0 ? string.Join(' ', nameParts) : kind.ToString();
                var (token, secret) = await tokens.CreateAsync(user.Id, kind, name, ct);
                Console.WriteLine($"Token {kind} creado para {user.Email} ({token.Id}).");
                Console.WriteLine("Cópialo ahora: no se volverá a mostrar.");
                Console.WriteLine();
                Console.WriteLine(secret);
                return 0;
            }

            case ["tokens", "list", var email]:
            {
                var user = await FindUserAsync(db, email, ct);
                if (user is null)
                {
                    return 1;
                }
                var list = await db.ApiTokens.Where(t => t.UserId == user.Id).OrderBy(t => t.CreatedAt).ToListAsync(ct);
                foreach (var t in list)
                {
                    var state = t.RevokedAt is null ? "activo " : "REVOCADO";
                    Console.WriteLine($"{t.Id}  {state}  {t.Kind,-11} {t.Prefix}…  \"{t.Name}\"  último uso: {t.LastUsedAt?.ToString("u") ?? "nunca"}");
                }
                return 0;
            }

            case ["tokens", "revoke", var idText] when Guid.TryParse(idText, out var id):
            {
                var revoked = await db.ApiTokens.Where(t => t.Id == id && t.RevokedAt == null)
                    .ExecuteUpdateAsync(s => s.SetProperty(t => t.RevokedAt, time.GetUtcNow()), ct);
                Console.WriteLine(revoked == 1 ? "Token revocado." : "No existe o ya estaba revocado.");
                return revoked == 1 ? 0 : 1;
            }

            default:
                Console.WriteLine("""
                    Uso:
                      users add <email>
                      users list
                      users delete <email> --yes        borra el usuario y TODOS sus datos
                      tokens create <email> device|integration [nombre]
                      tokens list <email>
                      tokens revoke <tokenId>
                      migrate
                    """);
                return args is ["help"] ? 0 : 2;
        }
    }

    private static string Normalize(string email) => email.Trim().ToLowerInvariant();

    private static async Task<User?> FindUserAsync(DirectoryDb db, string email, CancellationToken ct)
    {
        var user = await db.Users.FirstOrDefaultAsync(u => u.Email == Normalize(email), ct);
        if (user is null)
        {
            Console.Error.WriteLine($"No existe el usuario {email}");
        }
        return user;
    }
}
