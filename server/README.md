# ZydroSync — servidor

ASP.NET Core 10 (LTS) + EF Core + SQLite (un fichero por usuario). Implementa `../contract/openapi.yaml`.

```
src/ZydroSync.Api/
  Program.cs                 API o CLI de administración (mismo ejecutable)
  Data/DirectoryDb.cs        directory.db: usuarios y tokens
  Data/UserDb.cs             users/<userId>.db: entrenamientos de un usuario
  Data/DataStore.cs          rutas, migración de cada fichero al abrirlo, candado de escritura por usuario
  Data/Migrations/           Directory/ y User/ (dos esquemas)
  Data/Backup.cs             copias con VACUUM INTO
  Auth/                      tokens Bearer opacos (SHA-256), políticas device/integration/web/admin
  Workouts/WorkoutIngest.cs  POST /v1/workouts: validación, gzip con límites, idempotencia
  Workouts/WorkoutRead.cs    GET /v1/workouts (por serverId) y GET /v1/workouts/{id}
  Web/StaticSites.cs         cabeceras de seguridad y páginas estáticas (/ y /shared)
  Cli/AdminCli.cs            users / tokens / workouts / backup / migrate
  Admin/AdminPanel.cs        panel web /admin + API /admin/api (solo token admin, desactivado por defecto)
  wwwroot/web/               web «Mis carreras» (/): HTML + JS sin compilación
  wwwroot/admin/             panel de administración (/admin)
  wwwroot/shared/            común a los dos: detalle de carrera, estilos, Leaflet 1.9.4 (sha512 verificado)
tests/ZydroSync.Api.Tests/   xUnit + WebApplicationFactory con ficheros SQLite reales en un directorio temporal
Dockerfile                   imagen de producción (aspnet chiseled, sin shell, usuario sin privilegios, volumen /data)
compose.yaml                 opcional: probar la imagen de producción en local
deploy/                      despliegue en el Lightsail (deploy.sh), ver deploy/README.md
dotnet-tools.json            herramienta local dotnet-ef
```

## Datos en disco

```
<Storage:DataDirectory>/
  directory.db                 usuarios y tokens
  users/<userId>.db            entrenamientos de cada usuario (nombre = UUID, nunca el email)
```

En desarrollo, `server/data/` (excluido de git: contiene datos de salud). En producción, el
volumen `/data`.

## Requisitos

- **SDK de .NET 10** (LTS). Instalador oficial para macOS x64 (Mac Intel):
  https://dotnet.microsoft.com/download/dotnet/10.0, en "SDK 10.0.x", macOS, **x64 Installer (.pkg)**.
  No uses `brew install --cask dotnet-sdk`: instala la última versión (.NET 11) y los tests,
  que apuntan a net10.0, no tendrían runtime.

Nada más: no hay servidor de base de datos.

## Desarrollo

Desde `server/`:

```bash
dotnet test
```

```bash
dotnet run --project src/ZydroSync.Api
```

La API queda en http://localhost:8088, y desde el iPhone en http://<mac>.local:8088. Test de
contrato contra la API en marcha:

```bash
python3 ../tools/contract_test.py --base-url http://localhost:8088 --token zsd_...
```

Cambios de modelo (hay dos contextos):

```bash
dotnet tool restore
```

```bash
dotnet ef migrations add Nombre -p src/ZydroSync.Api -c UserDb -o Data/Migrations/User
```

```bash
dotnet ef migrations add Nombre -p src/ZydroSync.Api -c DirectoryDb -o Data/Migrations/Directory
```

El directorio se migra al arrancar. Cada fichero de usuario se migra la primera vez que se
abre tras arrancar, así que una migración nueva se aplica a todos sin ningún paso manual.

## Administración (etapa 1: altas a mano)

En local, desde `server/`. En producción, lo mismo con `deploy/deploy.sh cli …` (p. ej.
`deploy/deploy.sh cli users list`).

```bash
dotnet run --project src/ZydroSync.Api -- users add tu@email
dotnet run --project src/ZydroSync.Api -- tokens create tu@email device "iPhone de Isidro"
dotnet run --project src/ZydroSync.Api -- tokens create tu@email integration "ZydroTrack"
dotnet run --project src/ZydroSync.Api -- tokens create tu@email web "navegador"
dotnet run --project src/ZydroSync.Api -- tokens list tu@email
dotnet run --project src/ZydroSync.Api -- tokens revoke <tokenId>
dotnet run --project src/ZydroSync.Api -- users delete tu@email --yes    # borra TODOS sus datos y su fichero
dotnet run --project src/ZydroSync.Api -- workouts list tu@email [n]     # últimos n entrenamientos (50)
dotnet run --project src/ZydroSync.Api -- workouts json tu@email <id> > carrera.json   # payload original
```

El secreto de un token solo se muestra al crearlo. En la base de datos solo queda su SHA-256.

| Tipo | Prefijo | Para | Puede |
|---|---|---|---|
| `device` | `zsd_` | app iOS | subir y leer sus entrenamientos |
| `integration` | `zsi_` | ZydroTrack u otros importadores | leer sus entrenamientos |
| `web` | `zsw_` | web «Mis carreras» | leer sus entrenamientos |
| `admin` | `zsa_` | panel `/admin` | ver y borrar datos de **todos** los usuarios (solo en el panel) |

## Web «Mis carreras» (`/`)

`https://sync.isidrogilabert.com/` (en local, http://localhost:8088/): cada usuario pega su
token `web` y ve **sus** carreras: totales por año, lista por meses y el detalle de cada una
(mapa, parciales por km, gráficas y descarga del JSON). No puede subir ni borrar.

Lee la API pública (`GET /v1/workouts`, `GET /v1/workouts/{id}`), la misma que usará el
importador de ZydroTrack. El detalle de la carrera es código común con el panel
(`wwwroot/shared/`), así que los dos muestran lo mismo.

## Panel de administración (`/admin`)

Usuarios, tokens y entrenamientos de **todos** los usuarios:
- **crear usuarios**;
- **crear tokens** de cualquier tipo (el secreto se muestra una sola vez) y **revocarlos**;
- ver los entrenamientos de cada usuario con el mismo detalle que «Mis carreras», descargar
  el JSON y **borrar** un entrenamiento del servidor.

**En producción**, por túnel SSH (ver `deploy/README.md`):

```bash
deploy/deploy.sh cli tokens create tu@email admin "panel"   # una vez
deploy/tunnel.sh            # abre el túnel y http://localhost:18088/admin/
deploy/tunnel.sh down       # lo cierra
```

**En local:** `dotnet run --project src/ZydroSync.Api -- tokens create tu@email admin "panel"` y
http://localhost:8088/admin. El token se guarda solo en esa pestaña.

Por qué así:
- **Nunca se publica.** `Admin:LocalhostOnly` (activo por defecto) hace que `/admin` solo
  responda a peticiones con Host `localhost`/`127.0.0.1`, que solo llegan por el túnel: las
  que pasan por Caddy llevan el Host del dominio y reciben 404, igual que sin token (no un
  401 que revele que existe). Además, Caddy corta `/admin*` antes. `Admin:Enabled` está
  desactivado salvo en desarrollo y en el contenedor de producción.
- El token `admin` es el único que entra en `/admin/api`. Los demás tipos reciben 403, y un
  token admin no puede subir ni leer por la API pública.
- **CSP estricta:** solo se ejecuta JavaScript servido por el propio servidor, sin CDNs. La
  única petición externa son las teselas del mapa a `tile.openstreetmap.org`, que así
  conoce las zonas de las rutas que se visualizan.
- Las respuestas llevan `Cache-Control: no-store`: los datos de salud no quedan en la caché del navegador.

## Copias de seguridad

Un fichero SQLite en uso (modo WAL) **no se copia con `cp`**: la copia puede quedar
inconsistente. El comando `backup` hace `VACUUM INTO` de todas las bases de datos, con el
servidor en marcha, y comprueba cada copia con `PRAGMA quick_check`:

```bash
dotnet run --project src/ZydroSync.Api -- backup ../backups --keep 14
```

Cada copia va a `<directorio>/<yyyyMMdd-HHmmss>/`, con la misma estructura que `data/`.
Para restaurar, para el servidor y copia esos ficheros en su sitio. En producción se hace
cada día a las 03:30 (ver `deploy/README.md`).

## Decisiones

- **SQLite, un fichero por usuario.** Sin servidor de base de datos que mantener. Borrar un
  usuario es borrar su fichero (RGPD art. 17) y exportar sus datos es entregárselo. SQLite
  admite un escritor por fichero, y como cada usuario tiene el suyo, los usuarios no se
  bloquean entre sí. Si algún día hace falta, EF Core permite pasar a Postgres cambiando el proveedor.
- **Candado de escritura por usuario en el proceso** (`DataStore`): las subidas de un mismo
  usuario se serializan, así que el siguiente `seq` es `max + 1` sin carreras y SQLite no
  devuelve `SQLITE_BUSY`. Requiere **una sola instancia** del servidor, que es el despliegue previsto.
- **WAL** en todos los ficheros: las lecturas (la futura API de importación) no bloquean las escrituras.
- **Fechas como enteros** (ticks UTC): SQLite no tiene tipo fecha y EF Core no ordena
  DateTimeOffset guardados como texto.
- **Tokens opacos + SHA-256, no JWT.** Se pueden revocar al instante (una fila) y no hay
  claves de firma que rotar. Un token de 256 bits aleatorios no necesita un hash lento.
- **Dos tipos de token.** `device` solo escribe (la app) e `integration` solo lee
  (importadores, S3). Si se filtra el token de ZydroTrack, no sirve para inyectar datos.
- **El gzip original se guarda tal cual**, junto con el SHA-256 del JSON. "Reenvío idéntico"
  se decide por el hash; el bruto permite reprocesar en el futuro.
- **`seq` por usuario** como cursor del importador. Cambia al crear y al actualizar, así que
  el importador ve también las correcciones.
- **Límites:** 10 MB de cuerpo y 20 MB de JSON descomprimido, aplicados en streaming
  (una bomba gzip se corta sin inflarla), y 120 peticiones por minuto por token (429 + Retry-After).
- **Lector tolerante:** se exigen los campos obligatorios del contrato; los desconocidos se
  aceptan para que una app más nueva no rompa con un servidor más viejo.
