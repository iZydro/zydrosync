#!/usr/bin/env python3
"""Servidor de pruebas de ZydroTrack (POST /v1/workouts), solo biblioteca estándar.

Implementa el contrato de contract/openapi.yaml lo justo para probar la app:
  - Bearer token, Content-Encoding: gzip, Idempotency-Key == workoutId
  - 201 si es nueva, 200 si ya existía (idempotencia por UUID)
  - guarda cada carrera en <dir>/<workoutId>.json (legible, indentado)

Modos para provocar fallos (--mode):
  ok      todo bien (por defecto)
  500     siempre 500            → la app reintenta con backoff
  429     siempre 429 + Retry-After: 60
  401     siempre 401            → la app pausa la cola
  422     siempre 422            → error permanente
  flaky   1 de cada 2 peticiones falla con 503

Uso:
  python3 tools/mock_server.py --token secreto --port 8080 --dir /tmp/zydro-inbox
  URL en la app: http://<nombre-del-mac>.local:8080/v1/workouts
"""
import argparse
import gzip
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

args = None
counter = 0


def problem(handler, status, title, detail="", headers=None):
    body = json.dumps({"type": "about:blank", "title": title, "status": status, "detail": detail}).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/problem+json")
    for k, v in (headers or {}).items():
        handler.send_header(k, v)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        global counter
        counter += 1
        if self.path.rstrip("/") != "/v1/workouts":
            return problem(self, 404, "Not Found", self.path)
        if self.headers.get("Authorization") != f"Bearer {args.token}":
            return problem(self, 401, "Unauthorized", "Token incorrecto")

        mode = args.mode
        if mode == "flaky":
            mode = "503" if counter % 2 == 1 else "ok"
        if mode == "429":
            return problem(self, 429, "Too Many Requests", headers={"Retry-After": "60"})
        if mode in ("500", "503"):
            return problem(self, int(mode), "Server Error", "Fallo simulado")
        if mode == "401":
            return problem(self, 401, "Unauthorized", "Fallo simulado")
        if mode == "422":
            return problem(self, 422, "Unprocessable Content", "Fallo simulado")

        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            body = gzip.decompress(raw) if self.headers.get("Content-Encoding") == "gzip" else raw
            payload = json.loads(body)
        except Exception as e:  # noqa: BLE001
            return problem(self, 400, "Bad Request", f"Cuerpo ilegible: {e}")

        workout_id = payload.get("workoutId", "")
        if workout_id.upper() != self.headers.get("Idempotency-Key", "").upper():
            return problem(self, 422, "Unprocessable Content", "workoutId != Idempotency-Key")

        path = os.path.join(args.dir, f"{workout_id}.json")
        existed = os.path.exists(path)
        if not existed:
            with open(path, "w") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)

        route = payload.get("route") or {}
        series = payload.get("series") or {}
        print(f"{'200 dup' if existed else '201 new'}  {workout_id}  {payload.get('startDate')}  "
              f"{(payload.get('distanceM') or 0) / 1000:.2f} km  ruta={len(route.get('t', []))}  "
              f"series={','.join(sorted(series))}  gzip={len(raw) // 1024} KB  json={len(body) // 1024} KB",
              flush=True)

        out = json.dumps({"workoutId": workout_id, "status": "duplicate" if existed else "created"}).encode()
        self.send_response(200 if existed else 201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, fmt, *a):  # el print de arriba ya resume cada petición
        if args.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))


def main():
    global args
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--token", required=True)
    p.add_argument("--dir", default="/tmp/zydro-inbox")
    p.add_argument("--mode", default="ok", choices=["ok", "500", "429", "401", "422", "flaky"])
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    print(f"Escuchando en :{args.port}  modo={args.mode}  guardando en {args.dir}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
