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
ADMIN_PORT=18088
# Configuración privada (credenciales de ZydroLogin). Solo root la lee; nunca va a git.
PRIVATE_ENV=/home/ubuntu/zydrosync.env
LOGIN_ENV=/home/ubuntu/zydrologin.env
LOGIN_CALLBACK=https://sync.isidrogilabert.com/auth/callback
LOGIN_ISSUER=https://zydrotrack.isidrogilabert.com/login/
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
  local private=()
  if sudo -n test -f "$PRIVATE_ENV"; then private=(--env-file "$PRIVATE_ENV"); fi
  # Desde fuera solo se llega por Caddy. El puerto publicado lo está únicamente en el
  # loopback del servidor (127.0.0.1:$ADMIN_PORT), para el túnel SSH del panel de
  # administración (deploy/tunnel.sh). El panel solo responde a Host localhost
  # (Admin:LocalhostOnly), así que por Caddy da 404 aunque esté activo.
  # Sistema de ficheros de solo lectura salvo /data y /tmp, sin capacidades y con memoria
  # acotada (2 GB compartidos).
  $D run -d --name "$NAME" \
    --restart unless-stopped \
    --network "$NET" \
    -p "127.0.0.1:$ADMIN_PORT:8080" \
    -e Admin__Enabled=true \
    "${private[@]}" \
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

  swap_to "$release"

  configure_caddy "$domain" "$caddyfile" "$dir/Caddyfile.snippet" "$release"
  install_backup_timer "$dir"
  install -m 755 "$dir/remote.sh" "$BASE/remote.sh"
  cleanup
  log "Desplegada $release"
}

# Arranca la versión indicada en lugar de la que esté en marcha; si no responde, vuelve a la anterior.
swap_to() {
  local release="$1" had_previous=0
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

# Registra (o actualiza) ZydroSync como cliente de ZydroLogin y aplica la configuración:
#  1. zydrologin.env: añade/sustituye el registro "zydrosync" en ZYDROLOGIN_CLIENTS,
#     conservando los demás; secreto aleatorio de 64 caracteres (se reutiliza si ya existe).
#  2. zydrosync.env: las credenciales para el backend de ZydroSync.
#  3. Recrea el contenedor zydrologin con la configuración nueva (sus variables se fijan al
#     crearlo) y comprueba el descubrimiento por HTTPS. Si falla, lo restaura todo.
#  4. Recrea zydrosync para que lea zydrosync.env.
# Ningún secreto se imprime ni sale del servidor.
login_register() {
  [ $# -ge 2 ] || fail "Uso: remote.sh login-register <email admin> <email>..."
  # El mismo candado que los despliegues y copias de ZydroTrack: no tocar ZydroLogin a la vez.
  exec 8>/home/ubuntu/.zydrotrack-deploy.lock
  flock -n 8 || fail "ZydroTrack está desplegando o haciendo una copia; inténtalo en un rato."
  sudo -n test -f "$LOGIN_ENV" || fail "No existe $LOGIN_ENV"
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  local login_backup="$LOGIN_ENV.bak-zydrosync-$stamp"
  sudo -n cp -p "$LOGIN_ENV" "$login_backup"
  if sudo -n test -f "$PRIVATE_ENV"; then sudo -n cp -p "$PRIVATE_ENV" "$PRIVATE_ENV.bak-$stamp"; fi

  log "Registro del cliente zydrosync en ZydroLogin"
  sudo -n python3 - "$LOGIN_ENV" "$PRIVATE_ENV" "$LOGIN_ISSUER" "$LOGIN_CALLBACK" "$@" <<'PY'
import json, os, secrets, sys, tempfile
login_path, sync_path, issuer, callback, admin_email, *emails = sys.argv[1:]
emails.append(admin_email)

def read_env(path):
    if not os.path.exists(path):
        return []
    return open(path).read().splitlines()

def write_env(path, lines):
    # Atómico y 600 root desde el primer byte: el secreto nunca queda legible para otros.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".zydrosync-")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

login = read_env(login_path)
index = next(i for i, line in enumerate(login) if line.startswith("ZYDROLOGIN_CLIENTS="))
clients = json.loads(login[index].split("=", 1)[1])
private = dict(line.split("=", 1) for line in read_env(sync_path) if "=" in line and not line.startswith("#"))
secret = private.get("ZydroLogin__ClientSecret") or secrets.token_urlsafe(48)
assert len(secret) >= 32
allowed = sorted({e.strip().lower() for e in emails if "@" in e})
others = [c for c in clients if c.get("Id") != "zydrosync"]
registration = {"Id": "zydrosync", "Secret": secret, "RedirectUris": [callback], "Audience": "zydrosync",
                "Scopes": ["zydrosync:workouts:read", "zydrosync:admin"], "AllowedEmails": allowed}
login[index] = "ZYDROLOGIN_CLIENTS=" + json.dumps(others + [registration], separators=(",", ":"))
write_env(login_path, login)
private.update({"ZydroLogin__Issuer": issuer, "ZydroLogin__ClientId": "zydrosync",
                "ZydroLogin__ClientSecret": secret, "ZydroLogin__CallbackUri": callback,
                # Administrador por la web (panel /admin con ZydroLogin).
                "Admin__Emails__0": admin_email.strip().lower()})
write_env(sync_path, [f"{k}={v}" for k, v in private.items()])
print("Clientes:", ", ".join(c["Id"] for c in others + [registration]), "| zydrosync permite:", ", ".join(allowed),
      "| permisos:", ", ".join(registration["Scopes"]), "| admin:", admin_email)
PY

  local image old candidate
  image="$($D inspect zydrologin --format '{{.Config.Image}}')"
  old="$($D inspect zydrologin --format '{{.Id}}')"
  $D rm -f zydrologin-candidate-zs >/dev/null 2>&1 || true
  # Los mismos parámetros que activate.sh de ZydroTrack, con el env actualizado.
  candidate="$($D create --name zydrologin-candidate-zs --restart unless-stopped --network zydrotrack-net \
    --env-file "$LOGIN_ENV" -v zydrologin-data:/data "$image")"
  log "Reiniciando zydrologin con el registro nuevo"
  $D stop -t 20 "$old" >/dev/null
  $D rename "$old" "zydrologin-previous-zs-$stamp"
  $D rename "$candidate" zydrologin
  $D start zydrologin >/dev/null

  local ok=0
  for _ in $(seq 1 30); do
    if curl -fsS -m 5 "${LOGIN_ISSUER}.well-known/openid-configuration" 2>/dev/null | grep -q '"zydrosync:admin"'; then
      ok=1; break
    fi
    sleep 2
  done
  if [ "$ok" != 1 ]; then
    echo "--- últimas líneas de zydrologin ---" >&2
    $D logs --tail 20 zydrologin 2>&1 | grep -viE "secret|token" >&2 || true
    $D rm -f zydrologin >/dev/null
    $D rename "zydrologin-previous-zs-$stamp" zydrologin
    $D start zydrologin >/dev/null
    sudo -n cp -p "$login_backup" "$LOGIN_ENV"
    fail "ZydroLogin no arrancó con el registro nuevo. Restaurados el contenedor y $LOGIN_ENV."
  fi
  log "ZydroLogin publica los permisos de ZydroSync"

  local release
  release="$($D inspect "$NAME" --format '{{index .Config.Labels "zydrosync.release"}}')"
  swap_to "$release"
  log "ZydroSync usa ZydroLogin (versión $release). El contenedor anterior de login queda como zydrologin-previous-zs-$stamp"
}

case "${1:-}" in
  deploy) shift; [ $# -eq 3 ] || fail "Uso: remote.sh deploy <release> <dominio> <caddyfile>"; deploy "$@" ;;
  rollback) rollback ;;
  login-register) shift; login_register "$@" ;;
  *) fail "Uso: remote.sh deploy|rollback|login-register" ;;
esac
