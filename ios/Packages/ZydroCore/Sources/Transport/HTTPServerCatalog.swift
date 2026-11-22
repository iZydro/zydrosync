import Foundation
import SyncCore

/// GET /v1/workouts paginado: los `workoutId` que el servidor tiene de este usuario.
///
/// Usa la misma URL y el mismo token que la subida: el token de dispositivo también puede
/// leer (solo lo suyo). Se pide la lista entera o nada: con una lista a medias, la
/// reconciliación marcaría como ausentes carreras que sí están.
public struct HTTPServerCatalog: ServerCatalog {
    public static let pageSize = 500
    /// 500 × 200 = 100.000 carreras: de sobra, y evita un bucle si el servidor devolviera
    /// siempre el mismo cursor.
    static let maxPages = 200

    private let session: URLSession
    private let credentials: @Sendable () async -> BackendCredentials?
    private let clientVersion: String

    public init(session: URLSession = .shared, clientVersion: String,
                credentials: @escaping @Sendable () async -> BackendCredentials?) {
        self.session = session
        self.credentials = credentials
        self.clientVersion = clientVersion
    }

    struct Page: Decodable {
        struct Item: Decodable { let workoutId: UUID }
        let items: [Item]
        let nextAfter: String?
    }

    public func workoutIDs() async -> CatalogResult {
        guard let credentials = await credentials() else { return .failure("Falta URL o token") }
        var ids = Set<UUID>()
        var after: String?
        for _ in 0 ..< Self.maxPages {
            let request = Self.makeRequest(credentials: credentials, after: after, clientVersion: clientVersion)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                return .failure("No se pudo leer la lista del servidor: \(error.localizedDescription)")
            }
            guard let http = response as? HTTPURLResponse else { return .failure("Respuesta no HTTP") }
            switch http.statusCode {
            case 200:
                break
            case 401, 403:
                return .unauthorized(status: http.statusCode)
            default:
                let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                return .failure("La lista del servidor respondió \(http.statusCode) \(reason)")
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                return .failure("La lista del servidor no tiene el formato esperado")
            }
            ids.formUnion(page.items.map(\.workoutId))
            guard let next = page.nextAfter, next != after else { return .ids(ids) }
            after = next
        }
        return .failure("La lista del servidor tiene demasiadas páginas")
    }

    /// Pública y pura para testear sin red. La URL de la lista es la misma que la de subida.
    public static func makeRequest(credentials: BackendCredentials, after: String?, clientVersion: String) -> URLRequest {
        var components = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "limit", value: String(pageSize)))
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Client-Version")
        return request
    }
}
