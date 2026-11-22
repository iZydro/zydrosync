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
