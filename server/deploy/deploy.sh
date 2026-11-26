#!/usr/bin/env bash
# Despliegue de ZydroSync en el Lightsail, desde el Mac.
#
#   deploy/deploy.sh                    tests, publish, subida y cambio de contenedor
#   deploy/deploy.sh --skip-tests       sin pasar los tests antes
#   deploy/deploy.sh --allow-dirty      con cambios sin commit (la versión lleva "-dirty")
#
#   deploy/deploy.sh cli <args>         CLI de administración en producción, p. ej.
#                                         deploy/deploy.sh cli users list
#                                         deploy/deploy.sh cli tokens create yo@x.com device iPhone
#   deploy/deploy.sh logs [n]           últimas n líneas del log (100 por defecto)
#   deploy/deploy.sh status             versión en marcha, memoria y copias
#   deploy/deploy.sh backup             lanza la copia ahora (además de la diaria)
#   deploy/deploy.sh rollback           vuelve a la versión anterior
#   deploy/deploy.sh login-register     registra ZydroSync en ZydroLogin con los correos de los
#                                       usuarios de ZydroSync (más ZS_ADMIN_EMAIL) y lo aplica.
#                                       Repetir tras dar de alta usuarios nuevos. Reinicia
#                                       ZydroLogin unos segundos (también el login de ZydroTrack).
#
# Configurable por variables de entorno: ZS_HOST, ZS_SSH_KEY, ZS_DOMAIN, ZS_CADDYFILE.
#
# Cómo funciona: compila aquí con el SDK nativo (dotnet publish -r linux-x64), sube el
# resultado con rsync y en el servidor construye una imagen solo de ejecución (sin SDK:
# segundos y poca memoria). Si la versión nueva no responde en /healthz, vuelve sola a la
# anterior. Detalles en deploy/README.md; lo que corre en el servidor está en remote.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$(dirname "$HERE")"
REPO="$(dirname "$SERVER")"

ZS_HOST="${ZS_HOST:-ubuntu@54.246.27.40}"
ZS_SSH_KEY="${ZS_SSH_KEY:-$REPO/LightsailDefaultKey-eu-west-1.pem}"
ZS_DOMAIN="${ZS_DOMAIN:-sync.isidrogilabert.com}"
ZS_CADDYFILE="${ZS_CADDYFILE:-/home/ubuntu/zydrotrack/deploy/Caddyfile}"
ZS_ADMIN_EMAIL="${ZS_ADMIN_EMAIL:-isidrogilabert@gmail.com}"

SSH_OPTS=(-i "$ZS_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10)

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$ZS_SSH_KEY" ] || fail "No encuentro la clave SSH: $ZS_SSH_KEY (o define ZS_SSH_KEY)"

# Ejecuta en el servidor; cada argumento llega intacto (espacios, comillas…).
remote() { ssh "${SSH_OPTS[@]}" "$ZS_HOST" "$(printf '%q ' "$@")"; }

container_cli() { remote sudo -n docker exec zydrosync dotnet ZydroSync.Api.dll "$@"; }

deploy() {
  local skip_tests=0 allow_dirty=0
  for arg in "$@"; do
    case "$arg" in
      --skip-tests) skip_tests=1 ;;
      --allow-dirty) allow_dirty=1 ;;
      *) fail "Opción desconocida: $arg" ;;
    esac
  done

  # Lo desplegado debe ser un commit: así siempre se sabe qué código corre en producción.
  local dirty=""
  if [ -n "$(git -C "$REPO" status --porcelain -- server contract)" ]; then
    [ "$allow_dirty" = 1 ] || fail "Hay cambios sin commit en server/ o contract/ (usa --allow-dirty para desplegarlos igualmente)."
    dirty="-dirty"
  fi
  local release
  release="$(date -u +%Y%m%d-%H%M%S)-$(git -C "$REPO" rev-parse --short HEAD)$dirty"

  export PATH="/usr/local/share/dotnet:$HOME/.dotnet:$PATH"
  command -v dotnet >/dev/null || fail "No encuentro dotnet."

  if [ "$skip_tests" = 0 ]; then
    log "Tests"
    dotnet test "$SERVER" --nologo -v q >/tmp/zydrosync-tests.log 2>&1 \
      || { tail -30 /tmp/zydrosync-tests.log >&2; fail "Los tests fallan; no se despliega."; }
  fi

  local out="$SERVER/.deploy/$release"
  rm -rf "$SERVER/.deploy"
  log "Publicando $release (linux-x64)"
  dotnet publish "$SERVER/src/ZydroSync.Api" -c Release -r linux-x64 --self-contained false \
    -p:UseAppHost=false -o "$out/app" --nologo -v q >/tmp/zydrosync-publish.log 2>&1 \
    || { tail -30 /tmp/zydrosync-publish.log >&2; fail "dotnet publish ha fallado."; }
  # Solo para desarrollo (activa el panel /admin): fuera de la imagen de producción.
  rm -f "$out/app/appsettings.Development.json"
  cp "$HERE"/{Dockerfile.runtime,Caddyfile.snippet,zydrosync-backup.service,zydrosync-backup.timer,remote.sh} "$out/"

  log "Subiendo a $ZS_HOST"
  remote mkdir -p zydrosync/releases
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" "$out/" "$ZS_HOST:zydrosync/releases/$release/"

  remote bash "zydrosync/releases/$release/remote.sh" deploy "$release" "$ZS_DOMAIN" "$ZS_CADDYFILE"
  rm -rf "$SERVER/.deploy"

  # Desde fuera, por HTTPS. La primera vez Caddy tarda unos segundos en obtener el certificado.
  log "Comprobando https://$ZS_DOMAIN/healthz"
  for _ in $(seq 1 20); do
    if curl -fsS -m 5 "https://$ZS_DOMAIN/healthz" >/dev/null 2>&1; then
      log "Listo: https://$ZS_DOMAIN"
      return 0
    fi
    sleep 3
  done
  fail "El contenedor responde, pero https://$ZS_DOMAIN/healthz no. Revisa el DNS y: deploy/deploy.sh logs; ssh … sudo docker logs caddy"
}

status() {
  remote bash -s <<'EOF'
D="sudo -n docker"
echo "Versión:  $($D inspect zydrosync --format '{{index .Config.Labels "zydrosync.release"}}  ({{.State.Status}} desde {{.State.StartedAt}})' 2>/dev/null || echo 'no desplegado')"
prev="$($D inspect zydrosync-previous --format '{{index .Config.Labels "zydrosync.release"}}' 2>/dev/null)"
echo "Anterior: ${prev:-—}"
$D stats --no-stream --format 'Memoria:  {{.MemUsage}}  CPU {{.CPUPerc}}' zydrosync 2>/dev/null || true
echo "ZydroLogin: $(sudo -n test -f /home/ubuntu/zydrosync.env && echo configurado || echo 'sin configurar (deploy.sh login-register)')"
echo "Copias:"
$D run --rm -v zydrosync-data:/data:ro alpine:3.20 sh -c 'ls -1 /data/backups 2>/dev/null | tail -5; du -sh /data/users /data/backups 2>/dev/null'
systemctl list-timers zydrosync-backup.timer --no-pager | sed -n 2p
EOF
}

case "${1:-}" in
  ""|--*) deploy "$@" ;;
  cli) shift; [ $# -gt 0 ] || set -- help; container_cli "$@" ;;
  logs) remote sudo -n docker logs --tail "${2:-100}" zydrosync ;;
  status) status ;;
  backup) container_cli backup /data/backups --keep 14 ;;
  rollback) remote bash zydrosync/remote.sh rollback ;;
  login-register)
    # Solo usuarios conocidos por ZydroSync (y siempre el administrador).
    emails="$(container_cli users list | awk '{print $1}')"
    # shellcheck disable=SC2086
    remote bash zydrosync/remote.sh login-register "$ZS_ADMIN_EMAIL" $emails
    curl -fsS "https://$ZS_DOMAIN/auth/status" && echo ;;
  *) fail "Comando desconocido: $1 (mira la cabecera de deploy/deploy.sh)" ;;
esac
