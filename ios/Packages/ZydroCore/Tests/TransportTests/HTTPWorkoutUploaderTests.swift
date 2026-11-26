import Foundation
import SyncCore
import Testing
import Transport

@Suite("HTTPWorkoutUploader")
struct HTTPWorkoutUploaderTests {
    @Test("Petición: método, URL y cabeceras del contrato OpenAPI")
    func request() {
        let id = UUID(uuidString: "D061E7CC-5018-43B5-BE58-C09F8D89B005")!
        let creds = BackendCredentials(endpoint: URL(string: "https://api.zydrotrack.example/v1/workouts")!, token: "abc")
        let r = HTTPWorkoutUploader.makeRequest(credentials: creds, workoutID: id, clientVersion: "0.1.0 (1)")
        #expect(r.httpMethod == "POST")
        #expect(r.url == creds.endpoint)
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(r.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
        #expect(r.value(forHTTPHeaderField: "X-Client-Version") == "0.1.0 (1)")
    }

    @Test("Sin credenciales: no configurado")
    func notConfigured() async {
        let uploader = HTTPWorkoutUploader(clientVersion: "t") { nil }
        #expect(await uploader.isConfigured() == false)
    }
}

@Suite("HTTPServerCatalog")
struct HTTPServerCatalogTests {
    let creds = BackendCredentials(endpoint: URL(string: "https://sync.example/v1/workouts")!, token: "zsd_x")

    @Test("Lista: GET a la URL de subida, con página y cursor")
    func request() {
        let first = HTTPServerCatalog.makeRequest(credentials: creds, after: nil, clientVersion: "1 (2)")
        let next = HTTPServerCatalog.makeRequest(credentials: creds, after: "42", clientVersion: "1 (2)")
        #expect(first.httpMethod == "GET")
        #expect(first.url?.absoluteString == "https://sync.example/v1/workouts?limit=500")
        #expect(next.url?.absoluteString == "https://sync.example/v1/workouts?limit=500&after=42")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer zsd_x")
    }

    @Test("Sin credenciales: falla sin tocar la red")
    func notConfigured() async {
        let catalog = HTTPServerCatalog(clientVersion: "t") { nil }
        #expect(await catalog.workoutIDs() == .failure("Falta URL o token"))
    }
}

@Suite("AppLoginClient")
struct AppLoginClientTests {
    let client = AppLoginClient(baseURL: URL(string: "https://sync.example")!)

    @Test("PKCE S256: vector de prueba del RFC 7636")
    func pkceVector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let generated = PKCE.generate()
        #expect(generated.verifier.count == 64)
        #expect(generated.challenge.count == 43)
        #expect(PKCE.generate().verifier != generated.verifier)
    }

    @Test("Inicio: /auth/app/start con redirect, PKCE S256 y state; nunca el verifier")
    func startURL() {
        let attempt = client.begin(deviceName: "iPhone de Isidro", chooseAccount: true)
        let items = URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(attempt.url.path() == "/auth/app/start")
        #expect(value("redirect_uri") == "zydrosync://auth")
        #expect(value("code_challenge") == attempt.pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == attempt.state)
        #expect(value("device") == "iPhone de Isidro")
        #expect(value("prompt") == "login")
        #expect(!attempt.url.absoluteString.contains(attempt.pkce.verifier))
    }

    @Test("Vuelta: exige el state del intento; trae código o error")
    func callback() throws {
        let ok = URL(string: "zydrosync://auth?code=abc&state=S1")!
        #expect(try AppLoginClient.code(from: ok, expectedState: "S1") == "abc")
        #expect(throws: AppLoginError.stateMismatch) { try AppLoginClient.code(from: ok, expectedState: "S2") }
        #expect(throws: AppLoginError.stateMismatch) {
            try AppLoginClient.code(from: URL(string: "otra://auth?code=abc&state=S1")!, expectedState: "S1")
        }
        #expect(throws: AppLoginError.server(code: "no_account")) {
            try AppLoginClient.code(from: URL(string: "zydrosync://auth?error=no_account&state=S1")!, expectedState: "S1")
        }
        #expect(throws: AppLoginError.missingCode) {
            try AppLoginClient.code(from: URL(string: "zydrosync://auth?state=S1")!, expectedState: "S1")
        }
    }

    @Test("Canje: POST de formulario con code, verifier y redirect exacto")
    func redeemRequest() {
        let r = AppLoginClient.makeRedeemRequest(baseURL: URL(string: "https://sync.example")!, code: "c-1_x", verifier: "v~1.2")
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://sync.example/auth/app/token")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "code=c-1_x&code_verifier=v~1.2&redirect_uri=zydrosync://auth")
    }

    @Test("Origen a partir de la URL de subida")
    func origin() {
        #expect(AppLoginClient.origin(of: URL(string: "https://sync.example/v1/workouts")!)?.absoluteString == "https://sync.example")
        #expect(AppLoginClient.origin(of: URL(string: "http://mac.local:8088/v1/workouts")!)?.absoluteString == "http://mac.local:8088")
    }
}
