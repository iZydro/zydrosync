using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using ZydroSync.Api.Data;

namespace ZydroSync.Api.Login;

public sealed class SessionInvalidException : Exception;

/// <summary>Sesión resuelta: el access token vigente ya descifrado, solo en memoria.</summary>
public sealed record ActiveSession(Guid Id, Guid UserId, string Subject, string AccessToken, bool Admin);

/// <summary>
/// Sesiones web con ZydroLogin, guardadas en directory.db. La cookie lleva 256 bits
/// aleatorios; en la base de datos solo su SHA-256, y los tokens cifrados con Data Protection
/// (claves en &lt;datos&gt;/keys). Robar la base de datos no da acceso a ninguna sesión.
/// </summary>
public sealed class LoginSessions(DirectoryDb db, ZydroLoginClient login, IDataProtectionProvider protection,
    TimeProvider time, ILogger<LoginSessions> logger)
{
    public const string CookieName = "zs_session";
    /// <summary>Se renueva el access token cuando le queda menos de esto.</summary>
    private static readonly TimeSpan RefreshMargin = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan DefaultRefreshLifetime = TimeSpan.FromDays(7);
    private static readonly TimeSpan LastSeenResolution = TimeSpan.FromMinutes(5);
    /// <summary>Una sesión de administración no se alarga renovando: pasado esto, otra vez a ZydroLogin.</summary>
    public static readonly TimeSpan AdminLifetime = TimeSpan.FromHours(12);

    /// <summary>
    /// Un candado por sesión para renovar: el refresh token rota, así que dos peticiones
    /// simultáneas que renovaran a la vez gastarían el mismo token y la segunda tumbaría la sesión.
    /// </summary>
    private static readonly ConcurrentDictionary<Guid, SemaphoreSlim> RefreshLocks = new();

    private IDataProtector Protector => protection.CreateProtector("ZydroSync.LoginSession.Tokens");

    public static byte[] Hash(string cookieValue) => SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(cookieValue));

    /// <summary>Crea la sesión y devuelve el valor de la cookie (lo único que conoce el navegador).</summary>
    public async Task<string> CreateAsync(Guid userId, string subject, LoginTokens tokens, bool admin, CancellationToken ct)
    {
        var cookie = Base64Url.EncodeToString(RandomNumberGenerator.GetBytes(32));
        var now = time.GetUtcNow();
        db.LoginSessions.Add(new LoginSession
        {
            Id = Guid.CreateVersion7(),
            UserId = userId,
            Hash = Hash(cookie),
            Subject = subject,
            AccessToken = Protector.Protect(tokens.AccessToken),
            RefreshToken = tokens.RefreshToken is null ? null : Protector.Protect(tokens.RefreshToken),
            AccessTokenExpiresAt = tokens.AccessTokenExpiresAt,
            CreatedAt = now,
            LastSeenAt = now,
            ExpiresAt = Cap(admin, now, now + (tokens.RefreshToken is null ? tokens.AccessTokenExpiresAt - now : tokens.RefreshTokenLifetime ?? DefaultRefreshLifetime)),
            Admin = admin,
        });
        await db.SaveChangesAsync(ct);
        return cookie;
    }

    /// <summary>
    /// La sesión de esta cookie con un access token vigente, renovándolo si hace falta.
    /// SessionInvalidException: no existe, caducó o ZydroLogin rechazó la renovación (la
    /// sesión se borra: hay que volver a entrar). LoginProviderException(Unavailable): ZydroLogin
    /// no responde; la sesión se conserva y se rechaza esta petición.
    /// </summary>
    public async Task<ActiveSession> ResolveAsync(string cookie, CancellationToken ct)
    {
        var session = await FindAsync(cookie, ct) ?? throw new SessionInvalidException();
        var now = time.GetUtcNow();
        if (session.ExpiresAt <= now)
        {
            await DeleteLocalAsync(session, ct);
            throw new SessionInvalidException();
        }

        if (session.AccessTokenExpiresAt - now < RefreshMargin)
        {
            var gate = RefreshLocks.GetOrAdd(session.Id, _ => new SemaphoreSlim(1, 1));
            await gate.WaitAsync(ct);
            try
            {
                // Otra petición puede haber renovado mientras esperábamos.
                await db.Entry(session).ReloadAsync(ct);
                if (db.Entry(session).State == EntityState.Detached)
                {
                    throw new SessionInvalidException(); // la borró otra petición (logout)
                }
                if (session.AccessTokenExpiresAt - time.GetUtcNow() < RefreshMargin)
                {
                    await RefreshAsync(session, ct);
                }
            }
            finally
            {
                gate.Release();
            }
        }

        if (now - session.LastSeenAt > LastSeenResolution)
        {
            session.LastSeenAt = now;
            await db.SaveChangesAsync(ct);
        }
        return new ActiveSession(session.Id, session.UserId, session.Subject, Protector.Unprotect(session.AccessToken), session.Admin);
    }

    /// <summary>Cierre de sesión local: revoca en ZydroLogin los tokens de esta sesión y la borra.</summary>
    public async Task<bool> SignOutAsync(string cookie, CancellationToken ct)
    {
        var session = await FindAsync(cookie, ct);
        if (session is null)
        {
            return false;
        }
        var revoked = true;
        if (session.RefreshToken is { } refresh)
        {
            revoked &= await login.RevokeAsync(Protector.Unprotect(refresh), "refresh_token", ct);
        }
        revoked &= await login.RevokeAsync(Protector.Unprotect(session.AccessToken), "access_token", ct);
        if (!revoked)
        {
            logger.LogWarning("ZydroLogin no confirmó la revocación de los tokens de la sesión {SessionId}", session.Id);
        }
        await DeleteLocalAsync(session, ct);
        return revoked;
    }

    public async Task InvalidateAsync(Guid sessionId, CancellationToken ct)
    {
        await db.LoginSessions.Where(s => s.Id == sessionId).ExecuteDeleteAsync(ct);
        RefreshLocks.TryRemove(sessionId, out _);
    }

    private async Task<LoginSession?> FindAsync(string cookie, CancellationToken ct)
    {
        if (cookie.Length is 0 or > 100)
        {
            return null;
        }
        var hash = Hash(cookie);
        return await db.LoginSessions.FirstOrDefaultAsync(s => s.Hash == hash, ct);
    }

    private async Task RefreshAsync(LoginSession session, CancellationToken ct)
    {
        if (session.RefreshToken is null)
        {
            await DeleteLocalAsync(session, ct);
            throw new SessionInvalidException();
        }
        LoginTokens tokens;
        try
        {
            tokens = await login.RefreshAsync(Protector.Unprotect(session.RefreshToken), ct);
        }
        catch (LoginProviderException e) when (e.Failure == LoginFailure.Rejected)
        {
            await DeleteLocalAsync(session, ct);
            throw new SessionInvalidException();
        }
        var now = time.GetUtcNow();
        session.AccessToken = Protector.Protect(tokens.AccessToken);
        // Siempre el nuevo: el anterior ya no vale.
        if (tokens.RefreshToken is not null)
        {
            session.RefreshToken = Protector.Protect(tokens.RefreshToken);
            session.ExpiresAt = Cap(session.Admin, session.CreatedAt, now + (tokens.RefreshTokenLifetime ?? DefaultRefreshLifetime));
        }
        session.AccessTokenExpiresAt = tokens.AccessTokenExpiresAt;
        await db.SaveChangesAsync(ct);
    }

    private static DateTimeOffset Cap(bool admin, DateTimeOffset createdAt, DateTimeOffset expiresAt) =>
        admin && expiresAt > createdAt + AdminLifetime ? createdAt + AdminLifetime : expiresAt;

    private async Task DeleteLocalAsync(LoginSession session, CancellationToken ct)
    {
        db.LoginSessions.Remove(session);
        await db.SaveChangesAsync(ct);
        RefreshLocks.TryRemove(session.Id, out _);
    }
}
