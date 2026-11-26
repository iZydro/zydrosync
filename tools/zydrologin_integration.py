#!/usr/bin/env python3
"""Integración real ZydroSync ↔ ZydroLogin, en local y sin Google.

Levanta el ZydroLogin DE VERDAD (su código, modo Development: Google simulado en
localhost, como hace su propio tests/ZydroLogin/integration.py) y ZydroSync, y recorre el
login completo y los rechazos que pide la especificación.

  ZYDROLOGIN_DLL=/ruta/ZydroLogin.dll python3 tools/zydrologin_integration.py

ZydroLogin.dll se compila desde su repositorio (services/ZydroLogin). Es net8.0: con solo
.NET 10 instalado, se ejecuta con DOTNET_ROLL_FORWARD=Major (lo hace este script).
No usa secretos reales: todo vive en un directorio temporal que se borra al terminar.
"""
import base64, hashlib, http.server, json, os, pathlib, secrets, socket, subprocess, sys, tempfile, threading, time, urllib.parse
import requests

ROOT = pathlib.Path(__file__).resolve().parents[1]
API = ROOT / "server/src/ZydroSync.Api"
LOGIN_DLL = os.environ.get("ZYDROLOGIN_DLL") or sys.exit("Falta ZYDROLOGIN_DLL")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


GOOGLE = f"http://127.0.0.1:{free_port()}"
ISSUER = f"http://127.0.0.1:{free_port()}/login/"
SYNC = f"http://127.0.0.1:{free_port()}"
CALLBACK = SYNC + "/auth/callback"
SECRET_SYNC = secrets.token_urlsafe(40)
SECRET_TRACK = secrets.token_urlsafe(40)
PROFILES = {}  # email → perfil de Google simulado
CURRENT = {"email": None}
CODES = {}


class Google(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, value):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/authorize":
            code = secrets.token_urlsafe(24)
            CODES[code] = (q["code_challenge"][0], CURRENT["email"])
            self.send_response(302)
            self.send_header("Location", q["redirect_uri"][0] + "?" + urllib.parse.urlencode({"code": code, "state": q["state"][0]}))
            self.end_headers()
        else:  # userinfo: el perfil del último canje
            self.reply(PROFILES[self.headers["Authorization"].split(" ", 1)[1]])

    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        challenge, email = CODES.pop(q["code"][0])
        assert challenge == b64(hashlib.sha256(q["code_verifier"][0].encode()).digest())
        PROFILES[email] = {"sub": "google-" + hashlib.sha256(email.encode()).hexdigest()[:16], "email": email,
                           "email_verified": True, "name": email.split("@")[0]}
        self.reply({"access_token": email})


checks, processes = [], []


def check(condition, name):
    if not condition:
        raise AssertionError(name)
    checks.append(name)
    print("PASS", name, flush=True)


def start(command, env, cwd, health, log):
    p = subprocess.Popen(command, cwd=cwd, env={**os.environ, **env}, stdout=log, stderr=log)
    processes.append(p)
    for _ in range(150):
        try:
            if requests.get(health, timeout=1).status_code == 200:
                return p
        except requests.RequestException:
            pass
        if p.poll() is not None:
            raise RuntimeError(f"{command[1]} terminó al arrancar; mira {log.name}")
        time.sleep(0.2)
    raise RuntimeError("Arranque demasiado lento")


def follow(session, url, stop_prefix):
    """Sigue redirecciones como un navegador hasta llegar a una URL que empiece por stop_prefix."""
    r = session.get(url, allow_redirects=False)
    for _ in range(12):
        if not r.is_redirect:
            return r, None
        target = urllib.parse.urljoin(r.url, r.headers["Location"])
        if target.startswith(stop_prefix):
            return r, target
        r = session.get(target, allow_redirects=False)
    raise RuntimeError("Demasiadas redirecciones")


def browser_login(email, prompt=None, admin=False):
    """Login web completo. Devuelve (sesión del navegador, Location final de ZydroSync)."""
    CURRENT["email"] = email
    b = requests.Session()
    params = {k: v for k, v in {"prompt": "login" if prompt else None, "admin": "1" if admin else None}.items() if v}
    _, callback = follow(b, SYNC + "/auth/login" + ("?" + urllib.parse.urlencode(params) if params else ""), CALLBACK)
    r = b.get(callback, allow_redirects=False)
    return b, r.headers.get("Location")


def direct_tokens(client_id, secret, redirect, scope, email):
    """Código + PKCE fuera del navegador de ZydroSync, para obtener tokens de prueba."""
    CURRENT["email"] = email
    verifier = secrets.token_urlsafe(48)
    q = {"client_id": client_id, "redirect_uri": redirect, "response_type": "code", "scope": scope, "state": "s",
         "code_challenge_method": "S256", "code_challenge": b64(hashlib.sha256(verifier.encode()).digest())}
    _, back = follow(requests.Session(), ISSUER + "authorize?" + urllib.parse.urlencode(q), redirect)
    code = urllib.parse.parse_qs(urllib.parse.urlparse(back).query)["code"][0]
    r = requests.post(ISSUER + "token", data={"client_id": client_id, "client_secret": secret, "grant_type": "authorization_code",
                                              "code": code, "redirect_uri": redirect, "code_verifier": verifier})
    return r.json()


def cli(env, *args):
    out = subprocess.run(["dotnet", "bin/Debug/net10.0/ZydroSync.Api.dll", *args], cwd=API, env={**os.environ, **env},
                         capture_output=True, text=True, check=True).stdout
    return out.strip().splitlines()[-1]


google = http.server.ThreadingHTTPServer(("127.0.0.1", urllib.parse.urlparse(GOOGLE).port), Google)
threading.Thread(target=google.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="zydrosync-login-") as tmp:
        log = open(pathlib.Path(tmp) / "services.log", "w")
        clients = [
            {"Id": "zydrosync", "Secret": SECRET_SYNC, "RedirectUris": [CALLBACK], "Audience": "zydrosync",
             "Scopes": ["zydrosync:workouts:read", "zydrosync:admin"],
             "AllowedEmails": ["ana@example.test", "bea@example.test", "sin-cuenta@example.test"]},
            {"Id": "zydrotrack", "Secret": SECRET_TRACK, "RedirectUris": [SYNC + "/track"], "Audience": "zydrotrack",
             "Scopes": ["zydrotrack:session"], "AllowedEmails": ["ana@example.test"]},
        ]
        login_env = {"ASPNETCORE_ENVIRONMENT": "Development", "ASPNETCORE_URLS": ISSUER.split("/login")[0], "DOTNET_ROLL_FORWARD": "Major",
                     "ZYDROLOGIN_ISSUER": ISSUER, "ZYDROLOGIN_DATA": tmp + "/login", "ZYDROLOGIN_CLIENTS": json.dumps(clients),
                     "ZYDROLOGIN_GOOGLE_CLIENT_ID": "fake", "ZYDROLOGIN_GOOGLE_CLIENT_SECRET": "fake",
                     "ZYDROLOGIN_GOOGLE_REDIRECT_URI": ISSUER + "google/callback",
                     "ZYDROLOGIN_TEST_GOOGLE_AUTHORIZE": GOOGLE + "/authorize", "ZYDROLOGIN_TEST_GOOGLE_TOKEN": GOOGLE + "/token",
                     "ZYDROLOGIN_TEST_GOOGLE_USERINFO": GOOGLE + "/userinfo"}
        start(["dotnet", LOGIN_DLL], login_env, tmp, ISSUER + "health", log)

        sync_env = {"ASPNETCORE_ENVIRONMENT": "Production", "ASPNETCORE_URLS": SYNC, "Storage__DataDirectory": tmp + "/sync",
                    "ZydroLogin__Issuer": ISSUER, "ZydroLogin__ClientId": "zydrosync", "ZydroLogin__ClientSecret": SECRET_SYNC,
                    "ZydroLogin__CallbackUri": CALLBACK,
                    # Como en producción: panel activo, tokens admin solo por localhost, Ana es admin.
                    "Admin__Enabled": "true", "Admin__LocalhostOnly": "true", "Admin__Emails__0": "ana@example.test"}
        cli(sync_env, "users", "add", "ana@example.test")
        cli(sync_env, "users", "add", "bea@example.test")
        ana_device = cli(sync_env, "tokens", "create", "ana@example.test", "device")
        bea_device = cli(sync_env, "tokens", "create", "bea@example.test", "device")
        start(["dotnet", "bin/Debug/net10.0/ZydroSync.Api.dll"], sync_env, API, SYNC + "/healthz", log)

        def upload(device):
            wid = str(__import__("uuid").uuid4()).upper()
            body = {"schemaVersion": 1, "workoutId": wid, "sport": "running", "startDate": "2026-11-20T07:00:00Z",
                    "endDate": "2026-11-20T07:30:00Z", "durationSec": 1800, "elapsedSec": 1800, "indoor": False, "distanceM": 5000,
                    "source": {"bundleId": "com.apple.health.X", "name": "Watch", "productType": "Watch7,12"},
                    "route": {"t": [0, 1], "lat": [41.4, 41.41], "lon": [2.2, 2.21], "alt": [10, 11], "hAcc": [3, 3], "vAcc": [2, 2],
                              "speed": [3, 3], "course": [90, 90]}, "events": [], "series": {}}
            r = requests.post(SYNC + "/v1/workouts", json=body, headers={"Authorization": "Bearer " + device, "Idempotency-Key": wid})
            assert r.status_code == 201, r.text
            return wid.lower()

        ana_run, bea_run = upload(ana_device), upload(bea_device)

        meta = requests.get(ISSUER + ".well-known/openid-configuration").json()
        check("zydrosync:workouts:read" in meta["scopes_supported"], "ZydroLogin publica el permiso de ZydroSync")

        # 1. Recorrido completo y vínculo por sub.
        ana, location = browser_login("ana@example.test")
        check(location == "/", "login web completo: vuelve a /")
        check(ana.get(SYNC + "/auth/status").json()["user"]["email"] == "ana@example.test", "/auth/status con la sesión")
        cookie = ana.cookies.get("zs_session", domain=urllib.parse.urlparse(SYNC).hostname)
        check(cookie and "zs_session" not in ana.get(SYNC + "/auth/status").text, "la cookie es opaca y no se devuelve")
        items = ana.get(SYNC + "/v1/workouts").json()["items"]
        check([w["workoutId"] for w in items] == [ana_run], "ve sus carreras y no las de otros")
        check(ana.get(SYNC + f"/v1/workouts/{bea_run}").status_code == 404, "no puede leer una carrera de otro usuario")
        check(ana.get(SYNC + f"/v1/workouts/{ana_run}").json()["workoutId"].lower() == ana_run, "lee el detalle de la suya")

        # 2. state incorrecto.
        CURRENT["email"] = "ana@example.test"
        b = requests.Session()
        _, callback = follow(b, SYNC + "/auth/login", CALLBACK)
        bad = callback.replace("state=", "state=x")
        r = b.get(bad, allow_redirects=False)
        check(r.headers["Location"] == "/?login_error=invalid_state" and "zs_session" not in b.cookies, "state incorrecto rechazado")

        # 3. PKCE incorrecto: el código de un intento en el callback de otro navegador, y canje con otro verifier.
        attacker = requests.Session()
        _, stolen = follow(attacker, SYNC + "/auth/login", CALLBACK)
        victim = requests.Session()
        _, own = follow(victim, SYNC + "/auth/login", CALLBACK)
        code = urllib.parse.parse_qs(urllib.parse.urlparse(stolen).query)["code"][0]
        state = urllib.parse.parse_qs(urllib.parse.urlparse(own).query)["state"][0]
        r = victim.get(CALLBACK + "?" + urllib.parse.urlencode({"code": code, "state": state, "iss": ISSUER}), allow_redirects=False)
        check(r.headers["Location"] == "/?login_error=login_failed", "código con otro code_challenge (PKCE) rechazado")
        code2 = urllib.parse.parse_qs(urllib.parse.urlparse(own).query)["code"][0]
        r = requests.post(ISSUER + "token", data={"client_id": "zydrosync", "client_secret": SECRET_SYNC, "grant_type": "authorization_code",
                                                  "code": code2, "redirect_uri": CALLBACK, "code_verifier": "x" * 64})
        check(r.status_code == 400, "canje con code_verifier incorrecto rechazado por ZydroLogin")

        # 4. Callback no registrado.
        CURRENT["email"] = "ana@example.test"
        q = {"client_id": "zydrosync", "redirect_uri": "https://evil.test/callback", "response_type": "code",
             "scope": "openid zydrosync:workouts:read", "state": "s", "code_challenge_method": "S256", "code_challenge": b64(b"x" * 32)}
        r, back = follow(requests.Session(), ISSUER + "authorize?" + urllib.parse.urlencode(q), "https://evil.test")
        check(back is None, "callback no registrado: nunca recibe un código")

        # 5. Bearer de ZydroLogin: válido, revocado, otra audiencia.
        tokens = direct_tokens("zydrosync", SECRET_SYNC, CALLBACK, "openid email zydrosync:workouts:read", "ana@example.test")
        bearer = {"Authorization": "Bearer " + tokens["access_token"]}
        check(requests.get(SYNC + "/v1/workouts", headers=bearer).status_code == 200, "Bearer de ZydroLogin válido aceptado")
        requests.post(ISSUER + "revoke", data={"client_id": "zydrosync", "client_secret": SECRET_SYNC, "token": tokens["access_token"]})
        check(requests.get(SYNC + "/v1/workouts", headers=bearer).status_code == 401, "token revocado rechazado al instante")
        track = direct_tokens("zydrotrack", SECRET_TRACK, SYNC + "/track", "openid email zydrotrack:session", "ana@example.test")
        r = requests.get(SYNC + "/v1/workouts", headers={"Authorization": "Bearer " + track["access_token"]})
        check(r.status_code == 401, "token de ZydroTrack (otra audiencia) rechazado")
        check(requests.get(SYNC + "/v1/workouts", headers={"Authorization": "Bearer xyz"}).status_code == 401, "token inventado rechazado")

        # 6. Permisos: la sesión no puede subir.
        r = ana.post(SYNC + "/v1/workouts", data=b"{}", headers={"Content-Type": "application/json", "Idempotency-Key": ana_run})
        check(r.status_code == 403, "una sesión de lectura no puede subir carreras")

        # 7. Identidad sin cuenta en ZydroSync.
        _, location = browser_login("sin-cuenta@example.test")
        check(location == "/?login_error=no_account", "identidad sin usuario en ZydroSync: no entra ni se crea")

        # 8. Segundo usuario: aislado.
        bea, _ = browser_login("bea@example.test", prompt=True)
        check([w["workoutId"] for w in bea.get(SYNC + "/v1/workouts").json()["items"]] == [bea_run], "segundo usuario: solo lo suyo")

        # 9. Logout: Origin, revocación y SSO.
        check(ana.post(SYNC + "/auth/logout", headers={"Origin": "https://evil.test"}).status_code == 403, "logout desde otro origen rechazado")
        r = ana.post(SYNC + "/auth/logout", headers={"Origin": SYNC}).json()
        check(r["tokensRevoked"] and r["ssoSessionStillOpen"], "logout: tokens revocados en ZydroLogin; el SSO sigue")
        check(ana.get(SYNC + "/v1/workouts").status_code == 401, "tras el logout no hay acceso")
        _, location = browser_login("ana@example.test")
        check(location == "/", "volver a entrar tras el logout (por el SSO, sin bucles)")

        # 10. Panel de administración por la web.
        check(ana.get(SYNC + "/admin/api/users").status_code in (401, 403), "sin sesión de admin, el panel no responde datos")
        web_ana, _ = browser_login("ana@example.test")
        check(web_ana.get(SYNC + "/admin/api/users").status_code == 403, "la sesión normal del admin no administra (falta el permiso)")
        admin, location = browser_login("ana@example.test", admin=True)
        check(location == "/admin/", "login de administrador: vuelve al panel")
        users = admin.get(SYNC + "/admin/api/users")
        check(users.status_code == 200 and {u["email"] for u in users.json()} == {"ana@example.test", "bea@example.test"},
              "el administrador ve todos los usuarios")
        check(admin.get(SYNC + "/auth/status").json()["user"]["isAdmin"], "/auth/status marca la sesión como admin")
        check(admin.post(SYNC + "/admin/api/users", json={"email": "nuevo@example.test"}).status_code == 403,
              "cambios del panel sin Origin rechazados (CSRF)")
        created = admin.post(SYNC + "/admin/api/users", json={"email": "nuevo@example.test"}, headers={"Origin": SYNC})
        check(created.status_code == 201, "el administrador crea usuarios con Origin propio")
        _, location = browser_login("bea@example.test", admin=True)
        check(location == "/admin/?login_error=not_admin", "un usuario normal no puede entrar como administrador")

        services_log = (pathlib.Path(tmp) / "services.log").read_text()
        check(SECRET_SYNC not in services_log and cookie not in services_log and tokens["access_token"] not in services_log,
              "ni secretos, ni cookies, ni tokens en los logs de los servicios")
    print(f"{len(checks)} comprobaciones superadas")
finally:
    for p in processes:
        if p.poll() is None:
            p.terminate()
            p.wait(timeout=10)
    google.shutdown()
