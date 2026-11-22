#!/usr/bin/env python3
"""Test de contrato de POST /v1/workouts contra un servidor en marcha. Solo biblioteca estándar.

Comprueba lo que contract/openapi.yaml promete a los clientes: códigos de estado,
idempotencia, problem+json en errores y forma de IngestResult. Sirve igual contra el
servidor local que contra producción (como prueba de humo tras desplegar).

Usa un payload SINTÉTICO y un UUID nuevo en cada ejecución. En producción deja carreras de
prueba en la cuenta del token: usa un usuario de pruebas.

  python3 tools/contract_test.py --base-url http://localhost:8088 --token zsd_...
"""
import argparse
import gzip
import json
import sys
import urllib.error
import urllib.request
import uuid

FAILURES = []


def payload(workout_id, distance=5000.0):
    n = 5
    return {
        "schemaVersion": 1, "workoutId": workout_id, "sport": "running", "indoor": False,
        "startDate": "2026-01-01T08:00:00.000Z", "endDate": "2026-01-01T08:30:00.000Z",
        "durationSec": 1800.0, "elapsedSec": 1800.0, "distanceM": distance,
        "source": {"bundleId": "com.apple.health.CONTRACT-TEST", "name": "Contract test", "productType": "Watch7,12"},
        "events": [],
        "route": {"t": list(range(n)), "lat": [40.0] * n, "lon": [-3.0] * n},
        "series": {"heartRate": {"t": [0, 5], "v": [140, 150]}},
    }


def post(base, token, key, body, encoding="gzip", content_type="application/json"):
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if key:
        headers["Idempotency-Key"] = key
    if encoding:
        headers["Content-Encoding"] = encoding
    req = urllib.request.Request(f"{base}/v1/workouts", data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.headers.get("Content-Type", ""), json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            data = json.loads(raw) if raw else None
        except ValueError:
            data = raw.decode(errors="replace")
        return e.code, e.headers.get("Content-Type", ""), data


def check(name, condition, detail=""):
    print(f"  {'OK ' if condition else 'FALLA'}  {name}{'' if condition else f'  → {detail}'}")
    if not condition:
        FAILURES.append(name)


def gz(obj):
    return gzip.compress(json.dumps(obj).encode())


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", required=True)
    p.add_argument("--token", required=True, help="token de dispositivo (zsd_...)")
    p.add_argument("--integration-token", help="opcional: comprueba que un token de lectura no puede escribir")
    a = p.parse_args()
    base = a.base_url.rstrip("/")
    wid = str(uuid.uuid4()).upper()

    print(f"Contrato contra {base}  (workoutId {wid})")

    with urllib.request.urlopen(f"{base}/healthz", timeout=10) as r:
        check("GET /healthz → 200", r.status == 200)

    s, _, b = post(base, a.token, wid, gz(payload(wid)))
    check("alta → 201 created", s == 201 and b and b.get("status") == "created", (s, b))
    check("IngestResult: workoutId, status, serverId", b and {"workoutId", "status", "serverId"} <= set(b), b)

    s, _, b = post(base, a.token, wid, gz(payload(wid)))
    check("reenvío idéntico → 200 duplicate", s == 200 and b and b.get("status") == "duplicate", (s, b))

    s, _, b = post(base, a.token, wid, gz(payload(wid, distance=5100.0)))
    check("reenvío modificado → 200 updated", s == 200 and b and b.get("status") == "updated", (s, b))

    s, _, b = post(base, a.token, wid, json.dumps(payload(wid)).encode(), encoding=None)
    check("sin gzip también se acepta", s == 200, (s, b))

    s, ct, b = post(base, None, wid, gz(payload(wid)))
    check("sin token → 401 problem+json", s == 401 and "problem+json" in ct, (s, ct))

    s, ct, _ = post(base, a.token, str(uuid.uuid4()), gz(payload(wid)))
    check("Idempotency-Key distinto de workoutId → 422 problem+json", s == 422 and "problem+json" in ct, (s, ct))

    bad = payload(wid)
    del bad["source"]
    s, _, _ = post(base, a.token, wid, gz(bad))
    check("falta un campo obligatorio → 422", s == 422, s)

    s, _, _ = post(base, a.token, wid, gz(payload(wid)), encoding="br")
    check("Content-Encoding no soportado → 415", s == 415, s)

    if a.integration_token:
        s, _, _ = post(base, a.integration_token, wid, gz(payload(wid)))
        check("token de integración no puede escribir → 403", s == 403, s)

    print("Todo OK" if not FAILURES else f"{len(FAILURES)} fallos")
    sys.exit(1 if FAILURES else 0)


if __name__ == "__main__":
    main()
