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
