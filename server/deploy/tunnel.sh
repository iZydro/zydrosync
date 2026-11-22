#!/usr/bin/env bash
# Túnel SSH al panel de administración de producción.
#
#   deploy/tunnel.sh up        abre el túnel y el panel en el navegador (por defecto)
#   deploy/tunnel.sh down      cierra el túnel
#   deploy/tunnel.sh status    ¿está abierto?
#
# El panel no está publicado: Caddy da 404 en /admin y el servidor solo lo sirve a
# peticiones con Host localhost. El contenedor expone su puerto únicamente en el loopback
# del servidor (127.0.0.1:18088), y este túnel lo trae a http://localhost:18088 en el Mac.
# Cerrado el túnel, el panel deja de ser accesible desde cualquier sitio.
#
# Hace falta un token admin (zsa_…), que se crea una vez:
#   deploy/deploy.sh cli tokens create <email> admin "panel"
#
# Configurable con ZS_HOST, ZS_SSH_KEY y ZS_TUNNEL_PORT (puerto local, 18088 por defecto).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"

ZS_HOST="${ZS_HOST:-ubuntu@54.246.27.40}"
ZS_SSH_KEY="${ZS_SSH_KEY:-$REPO/LightsailDefaultKey-eu-west-1.pem}"
LOCAL_PORT="${ZS_TUNNEL_PORT:-18088}"
REMOTE_PORT=18088 # el de remote.sh (ADMIN_PORT)
URL="http://localhost:$LOCAL_PORT/admin/"
# Socket de control de SSH: permite cerrar exactamente este túnel y saber si sigue vivo,
# sin buscar procesos por nombre.
SOCKET="$HOME/.ssh/zydrosync-tunnel.sock"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

is_open() { [ -S "$SOCKET" ] && ssh -S "$SOCKET" -O check "$ZS_HOST" >/dev/null 2>&1; }

up() {
  if is_open; then
    log "El túnel ya está abierto: $URL"
  else
    [ -f "$ZS_SSH_KEY" ] || fail "No encuentro la clave SSH: $ZS_SSH_KEY (o define ZS_SSH_KEY)"
    rm -f "$SOCKET" # restos de un túnel que murió sin cerrarse
    if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      fail "El puerto $LOCAL_PORT ya está en uso en este Mac (¿un servidor local?). Usa ZS_TUNNEL_PORT=otro."
    fi
    log "Abriendo túnel localhost:$LOCAL_PORT → $ZS_HOST:127.0.0.1:$REMOTE_PORT"
    # -f: a segundo plano cuando el reenvío está listo (ExitOnForwardFailure lo garantiza).
    # -N: sin comando remoto. ServerAlive: detecta una conexión muerta (Wi-Fi, suspensión).
    ssh -i "$ZS_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -M -S "$SOCKET" -fN -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" "$ZS_HOST"
  fi

  if ! curl -fsS -m 5 "http://localhost:$LOCAL_PORT/healthz" >/dev/null; then
    fail "El túnel está abierto pero el servidor no responde (¿desplegado? deploy/deploy.sh status)"
  fi
  if ! curl -fsS -m 5 -o /dev/null "$URL"; then
    fail "El servidor responde pero el panel no (¿desplegada una versión con el panel activo?)"
  fi
  log "Panel: $URL  (cierra con: deploy/tunnel.sh down)"
  command -v open >/dev/null && open "$URL"
}

down() {
  if is_open; then
    ssh -S "$SOCKET" -O exit "$ZS_HOST" >/dev/null 2>&1 || true
    log "Túnel cerrado."
  else
    log "No había túnel abierto."
  fi
  rm -f "$SOCKET"
}

status() {
  if is_open; then
    log "Abierto: $URL"
  else
    log "Cerrado."
  fi
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) fail "Uso: deploy/tunnel.sh up|down|status" ;;
esac
