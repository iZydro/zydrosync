import Foundation
import SyncCore

public struct BackendCredentials: Sendable, Equatable {
    /// URL completa del endpoint, p. ej. https://api.zydrotrack.example/v1/workouts
    public var endpoint: URL
    public var token: String

    public init(endpoint: URL, token: String) {
        self.endpoint = endpoint
        self.token = token
    }
}

/// POST /v1/workouts con cuerpo gzip. Implementa WorkoutUploader: para cambiar de backend
/// basta con otro tipo que devuelva UploadOutcome.
///
/// Las credenciales se piden en cada envío (no se guardan aquí) para que un cambio de
/// token o URL desde la UI se aplique sin recrear nada.
///
/// Fase (c): URLSession normal con async/await. En la fase (d) se añadirá una variante con
/// URLSession en background que sube desde fichero, para que el envío sobreviva a la
/// suspensión de la app.
public struct HTTPWorkoutUploader: WorkoutUploader {
    private let session: URLSession
    private let credentials: @Sendable () async -> BackendCredentials?
    private let clientVersion: String
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared,
                clientVersion: String,
                now: @escaping @Sendable () -> Date = { Date() },
                credentials: @escaping @Sendable () async -> BackendCredentials?) {
        self.session = session
        self.credentials = credentials
        self.clientVersion = clientVersion
        self.now = now
    }

    public func isConfigured() async -> Bool {
        await credentials() != nil
    }

    public func upload(workoutID: UUID, gzippedJSON: Data) async -> UploadOutcome {
        guard let credentials = await credentials() else {
            return .retry(status: nil, after: nil, message: "Falta URL o token")
        }
        let request = Self.makeRequest(credentials: credentials, workoutID: workoutID, clientVersion: clientVersion)
        do {
            let (body, response) = try await session.upload(for: request, from: gzippedJSON)
            guard let http = response as? HTTPURLResponse else {
                return .retry(status: nil, after: nil, message: "Respuesta no HTTP")
            }
            return UploadOutcome.classify(
                status: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                body: body,
                now: now()
            )
        } catch {
            return UploadOutcome.classify(error: error)
        }
    }

    /// Pública y pura para poder testear las cabeceras sin red.
    ///
    /// `Authorization` está documentada por Apple como cabecera "reservada" de URLSession,
    /// pero ponerla en la petición funciona y es la práctica habitual. La alternativa, si
    /// algún día diera problemas en background, sería una cabecera propia (X-Api-Key).
    public static func makeRequest(credentials: BackendCredentials, workoutID: UUID, clientVersion: String) -> URLRequest {
        var request = URLRequest(url: credentials.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/json, application/problem+json", forHTTPHeaderField: "Accept")
        request.setValue(workoutID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
        return request
    }
}
