# ZydroSync — servidor

ASP.NET Core 10 (LTS) + EF Core + SQLite (un fichero por usuario). Implementa `../contract/openapi.yaml`.

```
src/ZydroSync.Api/
  Program.cs                 API o CLI de administración (mismo ejecutable)
  Data/DirectoryDb.cs        directory.db: usuarios y tokens
  Data/UserDb.cs             users/<userId>.db: entrenamientos de un usuario
  Data/DataStore.cs          rutas, migración de cada fichero al abrirlo, candado de escritura por usuario
  Data/Migrations/           Directory/ y User/ (dos esquemas)
  Auth/                      tokens Bearer opacos (SHA-256), políticas device/integration
  Workouts/                  POST /v1/workouts: validación, gzip con límites, idempotencia
  Cli/AdminCli.cs            users / tokens / migrate
tests/ZydroSync.Api.Tests/   xUnit + WebApplicationFactory con ficheros SQLite reales en un directorio temporal
Dockerfile                   imagen de producción (aspnet chiseled, sin shell, usuario sin privilegios, volumen /data)
compose.yaml                 opcional: probar la imagen de producción en local
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

En local, desde `server/` (en producción: `docker exec <contenedor> dotnet ZydroSync.Api.dll …`):

```bash
dotnet run --project src/ZydroSync.Api -- users add tu@email
dotnet run --project src/ZydroSync.Api -- tokens create tu@email device "iPhone de Isidro"
dotnet run --project src/ZydroSync.Api -- tokens create tu@email integration "ZydroTrack"
dotnet run --project src/ZydroSync.Api -- tokens list tu@email
dotnet run --project src/ZydroSync.Api -- tokens revoke <tokenId>
dotnet run --project src/ZydroSync.Api -- users delete tu@email --yes    # borra TODOS sus datos y su fichero
dotnet run --project src/ZydroSync.Api -- workouts list tu@email [n]     # últimos n entrenamientos (50)
dotnet run --project src/ZydroSync.Api -- workouts json tu@email <id> > carrera.json   # payload original
```

El secreto de un token solo se muestra al crearlo. En la base de datos solo queda su SHA-256.

## Copias de seguridad

Un fichero SQLite en uso (modo WAL) **no se copia con `cp`**: la copia puede quedar
inconsistente. Para cada fichero:

```bash
sqlite3 data/users/<id>.db "VACUUM INTO '/ruta/copia/<id>.db'"
```

Esto se automatizará en S2.

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
