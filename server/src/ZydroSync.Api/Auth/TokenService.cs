using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Auth;

/// <summary>
/// Tokens opacos de 256 bits aleatorios, guardados como SHA-256.
///
/// Por qué SHA-256 y no bcrypt/Argon2: esos algoritmos lentos protegen secretos de baja
/// entropía (contraseñas). Un token de 256 bits aleatorios no se puede atacar por fuerza
/// bruta, y un hash rápido permite buscarlo por índice en cada petición. Si se filtra la
/// base de datos, los hashes no sirven para autenticarse.
/// </summary>
public sealed class TokenService(DirectoryDb db, TimeProvider time)
{
    public const string DevicePrefix = "zsd_";
    public const string IntegrationPrefix = "zsi_";
    public const string AdminPrefix = "zsa_";
    public const string WebPrefix = "zsw_";

    public async Task<(ApiToken Token, string Secret)> CreateAsync(Guid userId, TokenKind kind, string name, CancellationToken ct)
    {
        var prefix = kind switch
        {
            TokenKind.Device => DevicePrefix,
            TokenKind.Integration => IntegrationPrefix,
            TokenKind.Web => WebPrefix,
            TokenKind.Admin => AdminPrefix,
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        var secret = prefix + Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));
        var token = new ApiToken
        {
            Id = Guid.CreateVersion7(),
            UserId = userId,
            Name = name,
            Kind = kind,
            Hash = Hash(secret),
            Prefix = secret[..10],
            CreatedAt = time.GetUtcNow(),
        };
        db.ApiTokens.Add(token);
        await db.SaveChangesAsync(ct);
        return (token, secret);
    }

    /// <summary>"Bearer zsd_…" / zsi_ / zsw_ / zsa_: un token propio (y no uno de ZydroLogin).</summary>
    public static bool IsOwnToken(string authorizationHeader) =>
        authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
        && authorizationHeader.AsSpan(7).TrimStart() is var token
        && (token.StartsWith(DevicePrefix) || token.StartsWith(IntegrationPrefix) || token.StartsWith(WebPrefix) || token.StartsWith(AdminPrefix));

    public static byte[] Hash(string secret) => SHA256.HashData(Encoding.UTF8.GetBytes(secret));
}
