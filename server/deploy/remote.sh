#!/usr/bin/env bash
# Se ejecuta EN EL SERVIDOR; lo lanza deploy.sh. No hace falta usarlo a mano.
#
#   remote.sh deploy <release> <dominio> <ruta del Caddyfile>
#   remote.sh rollback
#
# Convive con ZydroTrack sin tocar lo suyo: red, volumen y contenedor propios. Lo único
# compartido es Caddy, al que se conecta a nuestra red y se le añade un bloque delimitado
# por marcadores en su Caddyfile.
set -euo pipefail

BASE="$HOME/zydrosync"
NAME=zydrosync
NET=zydrosync-net
VOL=zydrosync-data
CADDY=caddy
KEEP_RELEASES=3
D="sudo -n docker"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$BASE"
exec 9>"$BASE/.deploy.lock"
flock -n 9 || fail "Hay otro despliegue en curso."

exists() { $D container inspect "$1" >/dev/null 2>&1; }

# /healthz a través de la red de Docker, desde el contenedor de Caddy (la imagen chiseled
# no tiene curl ni wget). Es el mismo camino que seguirán las peticiones reales.
healthy() {
  for _ in $(seq 1 30); do
    if $D exec "$CADDY" wget -qO- -T 2 "http://$NAME:8080/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_network() {
  $D network inspect "$NET" >/dev/null 2>&1 || { log "Red $NET"; $D network create "$NET" >/dev/null; }
  # Red propia y no zydrotrack-net: ZydroSync no tiene por qué ver el Postgres de ZydroTrack.
  # Se comprueba en cada despliegue por si ZydroTrack recrea el contenedor de Caddy.
  if ! $D inspect "$CADDY" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw "$NET"; then
    log "Conectando $CADDY a $NET"
    $D network connect "$NET" "$CADDY"
  fi
}

ensure_volume() {
  if ! $D volume inspect "$VOL" >/dev/null 2>&1; then
    log "Volumen $VOL"
    $D volume create "$VOL" >/dev/null
    # La imagen chiseled corre como uid 1654 y no tiene shell para preparar el directorio.
    $D run --rm -v "$VOL:/data" alpine:3.20 sh -c 'mkdir -p /data/users /data/backups && chown -R 1654:1654 /data'
  fi
}

run_container() {
  # Sin puertos publicados: solo se llega por Caddy. Sistema de ficheros de solo lectura
  # salvo /data y /tmp, sin capacidades y con memoria acotada (2 GB compartidos).
  $D run -d --name "$NAME" \
    --restart unless-stopped \
    --network "$NET" \
    --memory 256m --cpus 1 \
    --read-only --tmpfs /tmp:rw,size=64m \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-opt max-size=10m --log-opt max-file=3 \
    -v "$VOL:/data" \
    --label "zydrosync.release=$1" \
    "zydrosync:$1" >/dev/null
}

configure_caddy() {
  local domain="$1" caddyfile="$2" snippet="$3" release="$4"
  [ -f "$caddyfile" ] || fail "No existe $caddyfile"
  local desired
  desired="$(mktemp)"
  # El Caddyfile actual sin nuestro bloque, más el bloque actualizado.
  python3 - "$caddyfile" "$snippet" "$domain" >"$desired" <<'PY'
import re, sys
current = open(sys.argv[1]).read()
block = open(sys.argv[2]).read().replace("__DOMAIN__", sys.argv[3])
stripped = re.sub(r"\n*# --- ZydroSync .*?# --- fin ZydroSync ---\n?", "\n", current, flags=re.S).rstrip("\n") + "\n"
sys.stdout.write(stripped + block)
PY
  if cmp -s "$desired" "$caddyfile"; then
    rm -f "$desired"
    return 0
  fi
  log "Caddy: bloque $domain"
  cp -p "$caddyfile" "$caddyfile.bak-zydrosync-$release"
  # Escribir encima (cat >) y no sustituir el fichero: está montado en el contenedor de
  # Caddy como fichero suelto, y un fichero nuevo (otro inodo) no se vería dentro.
  cat "$desired" >"$caddyfile"
  rm -f "$desired"
  if ! $D exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/zydrosync-caddy.log 2>&1; then
    cat "$caddyfile.bak-zydrosync-$release" >"$caddyfile"
    tail -5 /tmp/zydrosync-caddy.log >&2
    fail "El Caddyfile nuevo no valida; se ha dejado el anterior."
  fi
  # reload y no restart: ZydroTrack no se entera.
  $D exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 \
    || fail "caddy reload ha fallado (el Caddyfile valida; revisa: sudo docker logs caddy)"
}

install_backup_timer() {
  local dir="$1" changed=0
  for unit in zydrosync-backup.service zydrosync-backup.timer; do
    if ! cmp -s "$dir/$unit" "/etc/systemd/system/$unit"; then
      sudo -n install -m 644 "$dir/$unit" "/etc/systemd/system/$unit"
      changed=1
    fi
  done
  if [ "$changed" = 1 ]; then
    log "Copia diaria (systemd)"
    sudo -n systemctl daemon-reload
  fi
  sudo -n systemctl enable --now zydrosync-backup.timer >/dev/null 2>&1
}

cleanup() {
  # Solo las últimas versiones: imágenes y carpetas. La del contenedor anterior se queda
  # mientras exista (Docker no deja borrar una imagen en uso), para poder volver atrás.
  ls -1d "$BASE"/releases/*/ 2>/dev/null | sort | head -n -"$KEEP_RELEASES" | xargs -r rm -rf
  $D images zydrosync --format '{{.Tag}}' | sort -r | tail -n +"$((KEEP_RELEASES + 1))" \
    | while read -r tag; do $D rmi "zydrosync:$tag" >/dev/null 2>&1 || true; done
}

deploy() {
  local release="$1" domain="$2" caddyfile="$3"
  local dir="$BASE/releases/$release"
  [ -d "$dir/app" ] || fail "No está subida la versión $release"

  log "Imagen zydrosync:$release"
  $D build --quiet -t "zydrosync:$release" -f "$dir/Dockerfile.runtime" "$dir" >/dev/null

  ensure_network
  ensure_volume

  local had_previous=0
  if exists "$NAME"; then
    log "Parando la versión en marcha"
    $D rm -f "$NAME-previous" >/dev/null 2>&1 || true
    $D stop -t 20 "$NAME" >/dev/null
    $D rename "$NAME" "$NAME-previous"
    had_previous=1
  fi

  log "Arrancando $release"
  run_container "$release"
  if ! healthy; then
    echo "--- últimas líneas de log ---" >&2
    $D logs --tail 40 "$NAME" >&2 || true
    $D rm -f "$NAME" >/dev/null
    if [ "$had_previous" = 1 ]; then
      $D rename "$NAME-previous" "$NAME"
      $D start "$NAME" >/dev/null
      fail "La versión nueva no responde en /healthz. Restaurada la anterior."
    fi
    fail "La versión nueva no responde en /healthz."
  fi

  configure_caddy "$domain" "$caddyfile" "$dir/Caddyfile.snippet" "$release"
  install_backup_timer "$dir"
  install -m 755 "$dir/remote.sh" "$BASE/remote.sh"
  cleanup
  log "Desplegada $release"
}

rollback() {
  exists "$NAME-previous" || fail "No hay versión anterior a la que volver."
  local current previous
  current="$($D inspect "$NAME" --format '{{index .Config.Labels "zydrosync.release"}}' 2>/dev/null || echo "?")"
  previous="$($D inspect "$NAME-previous" --format '{{index .Config.Labels "zydrosync.release"}}')"
  log "Volviendo de $current a $previous"
  $D rm -f "$NAME-broken" >/dev/null 2>&1 || true
  if exists "$NAME"; then
    $D stop -t 20 "$NAME" >/dev/null
    $D rename "$NAME" "$NAME-broken"
  fi
  $D rename "$NAME-previous" "$NAME"
  $D start "$NAME" >/dev/null
  healthy || fail "La versión anterior tampoco responde en /healthz."
  log "En marcha $previous (la otra queda parada como $NAME-broken)"
}

case "${1:-}" in
  deploy) shift; [ $# -eq 3 ] || fail "Uso: remote.sh deploy <release> <dominio> <caddyfile>"; deploy "$@" ;;
  rollback) rollback ;;
  *) fail "Uso: remote.sh deploy|rollback" ;;
esac
