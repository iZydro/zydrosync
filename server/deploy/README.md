# Despliegue (Lightsail)

```bash
deploy/deploy.sh                    # tests → publish → subida → cambio de contenedor
deploy/deploy.sh status             # versión en marcha, memoria, copias
deploy/deploy.sh logs [n]
deploy/deploy.sh cli users list     # cualquier comando de la CLI, en producción
deploy/deploy.sh backup             # copia ahora (además de la diaria)
deploy/deploy.sh rollback           # vuelve a la versión anterior

deploy/tunnel.sh                    # túnel SSH al panel /admin y lo abre en el navegador
deploy/tunnel.sh down | status
```

Se ejecuta desde `server/` o desde cualquier sitio: las rutas son relativas al script. Por
defecto apunta a `ubuntu@54.246.27.40` con la clave `LightsailDefaultKey-eu-west-1.pem` de
la raíz del repo (ignorada por git) y a `sync.isidrogilabert.com`. Se cambia con `ZS_HOST`,
`ZS_SSH_KEY`, `ZS_DOMAIN` y `ZS_CADDYFILE`.

## Qué hace

1. **Comprobaciones:** se niega a desplegar con cambios sin commit en `server/` o `contract/`,
   para que siempre se sepa qué código corre (`--allow-dirty` para saltárselo; la versión
   lleva entonces `-dirty`). Pasa los tests (`--skip-tests` para no hacerlo).
2. **Compila en el Mac** con el SDK nativo: `dotnet publish -r linux-x64`, unos 8 MB.
3. **Sube con rsync** a `~/zydrosync/releases/<fecha>-<commit>/`.
4. **En el servidor** (`remote.sh`):
   - construye una imagen **solo de ejecución** (`aspnet:10.0-noble-chiseled` + `COPY`):
     sin SDK, segundos y casi sin memoria;
   - para la versión en marcha (queda como `zydrosync-previous`), arranca la nueva y espera
     a `/healthz`. **Si no responde, vuelve sola a la anterior**;
   - añade o actualiza su bloque en el Caddyfile, lo valida y hace `caddy reload`;
   - instala el timer de la copia diaria;
   - conserva solo las 3 últimas versiones (carpetas e imágenes).
5. **Comprueba desde fuera** `https://sync.isidrogilabert.com/healthz`.

## Cómo convive con ZydroTrack

| | ZydroSync | ZydroTrack |
|---|---|---|
| Contenedor | `zydrosync` | `zydrotrack`, `zydrotrack-db` |
| Red | `zydrosync-net` | `zydrotrack-net` |
| Datos | volumen `zydrosync-data` (`/data`) | `zydrotrack-data`, `zydrotrack-postgres` |
| Caddy | compartido | compartido |

- **Red propia:** ZydroSync no ve el Postgres de ZydroTrack. Caddy se conecta a las dos
  redes; el despliegue lo comprueba cada vez, por si ZydroTrack recrea su contenedor.
- **Caddyfile compartido** (`~/zydrotrack/deploy/Caddyfile`, montado en Caddy): el bloque de
  ZydroSync va entre los marcadores `# --- ZydroSync` y `# --- fin ZydroSync ---`. No edites
  dentro: el despliegue lo reescribe. Antes de cambiarlo guarda una copia
  (`Caddyfile.bak-zydrosync-<versión>`). Se reescribe en el sitio y no se sustituye, porque
  un fichero suelto montado en Docker deja de verse dentro si cambia de inodo.
- `/admin` da 404 también en Caddy: el panel no se publica.

## Panel de administración (túnel)

```bash
deploy/deploy.sh cli tokens create tu@email admin "panel"   # una vez; guarda el zsa_…
deploy/tunnel.sh                                            # abre http://localhost:18088/admin/
deploy/tunnel.sh down
```

`tunnel.sh` abre `ssh -L 127.0.0.1:18088:127.0.0.1:18088` en segundo plano con un socket de
control (`~/.ssh/zydrosync-tunnel.sock`), para poder cerrarlo o comprobarlo sin buscar
procesos. Comprueba que el servidor y el panel responden y abre el navegador.

El panel está activo en el contenedor (`Admin__Enabled=true`) pero con `Admin:LocalhostOnly`:
solo atiende peticiones con Host `localhost`, que es lo que envía el navegador por el túnel.
Por Caddy llega con Host `sync.isidrogilabert.com` y recibe 404. Tres capas: Caddy corta
`/admin*`, el servidor rechaza cualquier Host que no sea local, y hace falta un token admin.

## El contenedor

- **Desde fuera solo se llega por Caddy.** El único puerto publicado es `127.0.0.1:18088`, en
  el loopback del servidor, para el túnel del panel de administración.
- **Restricciones:** sistema de ficheros de solo lectura salvo `/data` y `/tmp`, sin capacidades
  (`--cap-drop ALL`), `no-new-privileges` y usuario sin privilegios (uid 1654).
- **Recursos:** `--memory 256m` (usa unos 60 MB) y GC de estación de trabajo. La máquina
  tiene 2 GB compartidos con ZydroTrack, más 1 GB de swap.
- **Logs** de Docker con rotación: 10 MB × 3.
- Los avisos de DataProtection (claves efímeras) se silencian en `appsettings.json`: la API
  no usa cookies ni nada que cifre con esas claves.

## Copias

`zydrosync-backup.timer` ejecuta cada día a las 03:30 (±15 min)
`backup /data/backups --keep 14` dentro del contenedor. Las copias quedan en el mismo
volumen: protegen de errores y de corrupción, **no de perder la máquina**. Para eso
están las instantáneas de Lightsail. Pendiente: llevarlas fuera (p. ej. con el restic a S3
que ya usa ZydroTrack).

Para restaurar un usuario:

```bash
ssh … sudo docker stop zydrosync
ssh … sudo docker run --rm -v zydrosync-data:/data alpine:3.20 \
  cp /data/backups/<fecha>/users/<id>.db /data/users/<id>.db   # y borrar <id>.db-wal / -shm
ssh … sudo docker start zydrosync
```

## Primer despliegue

```bash
deploy/deploy.sh
deploy/deploy.sh cli users add tu@email
deploy/deploy.sh cli tokens create tu@email device "iPhone"
```

En la app: URL `https://sync.isidrogilabert.com`, pega el token, y "Borrar enviadas y
volver a enviar".
