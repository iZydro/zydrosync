using Microsoft.Extensions.FileProviders;

namespace ZydroSync.Api.Web;

/// <summary>
/// Páginas estáticas, sin compilación:
///   /          web «Mis carreras» (wwwroot/web), para cualquier usuario con un token web
///   /shared/   código y estilos comunes a la web y al panel, y Leaflet (wwwroot/shared)
///   /admin/    panel de administración (AdminPanel), solo si está activado
/// </summary>
public static class StaticSites
{
    /// <summary>
    /// Cabeceras de seguridad en todas las respuestas. Sin JavaScript de terceros: Leaflet se
    /// sirve desde aquí y solo las teselas del mapa vienen de OpenStreetMap. 'unsafe-inline'
    /// en estilos lo exige Leaflet (posiciona con style="…"); en scripts no se permite.
    /// </summary>
    public static WebApplication UseSecurityHeaders(this WebApplication app)
    {
        app.Use(async (ctx, next) =>
        {
            var h = ctx.Response.Headers;
            h.ContentSecurityPolicy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
                                      "img-src 'self' data: https://tile.openstreetmap.org; connect-src 'self'; " +
                                      "frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
            h.XContentTypeOptions = "nosniff";
            h.XFrameOptions = "DENY";
            // OpenStreetMap exige Referer en las teselas: se envía solo el origen.
            h["Referrer-Policy"] = "strict-origin-when-cross-origin";
            // Datos de salud: nada en la caché del navegador ni de intermediarios.
            h.CacheControl = "no-store";
            await next();
        });
        return app;
    }

    public static WebApplication MapStaticSites(this WebApplication app)
    {
        var root = app.Environment.WebRootPath ?? Path.Combine(app.Environment.ContentRootPath, "wwwroot");
        var shared = new PhysicalFileProvider(Path.Combine(root, "shared"));
        var web = new PhysicalFileProvider(Path.Combine(root, "web"));
        app.UseStaticFiles(new StaticFileOptions { RequestPath = "/shared", FileProvider = shared });
        app.UseDefaultFiles(new DefaultFilesOptions { FileProvider = web });
        app.UseStaticFiles(new StaticFileOptions { FileProvider = web });
        return app;
    }
}
