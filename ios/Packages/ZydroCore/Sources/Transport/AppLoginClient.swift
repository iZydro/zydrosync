import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636) generado en el iPhone: el `verifier` no sale del dispositivo hasta el canje.
public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.challenge(for: verifier)
    }

    /// 48 bytes aleatorios → 64 caracteres base64url (RFC 7636 pide 43–128).
    public static func generate() -> PKCE {
        PKCE(verifier: randomString(bytes: 48))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomString(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(status == errSecSuccess, "Sin generador aleatorio seguro")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum AppLoginError: Error, Sendable, Equatable {
    /// La vuelta no corresponde a este intento (otra pestaña, o alguien intentando colarla).
    case stateMismatch
    /// El servidor devolvió un error en la vuelta: no_account, access_denied, unavailable…
    case server(code: String)
    case missingCode
    /// El canje fue rechazado (código usado, caducado o verifier que no coincide).
    case rejected(status: Int)
    case invalidResponse
    case network(String)
}

public struct AppLoginResult: Sendable, Equatable, Decodable {
    public let token: String
    public let tokenId: UUID
    public let email: String
    public let uploadUrl: URL
}

/// Login de la app con ZydroLogin a través de ZydroSync (ver Login/AppLogin.cs en el servidor):
///  1. `begin` → URL de /auth/app/start con el PKCE y el state de este intento;
///  2. la app la abre en ASWebAuthenticationSession y recibe zydrosync://auth?code=…&state=…;
///  3. `code(from:)` comprueba el state; `redeem` canjea el código con el verifier y devuelve
///     un token de dispositivo de ZydroSync.
/// La app no tiene ni necesita ningún secreto.
public struct AppLoginClient: Sendable {
    public static let callbackScheme = "zydrosync"
    public static let redirectURI = "zydrosync://auth"

    public struct Attempt: Sendable, Equatable {
        public let pkce: PKCE
        public let state: String
        public let url: URL
    }

    public let baseURL: URL
    private let session: URLSession

    /// `baseURL`: el origen del servidor (https://sync.isidrogilabert.com).
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// El origen a partir de la URL de subida configurada (…/v1/workouts).
    public static func origin(of endpoint: URL) -> URL? {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host()
        components.port = endpoint.port
        return components.url
    }

    public func begin(deviceName: String, chooseAccount: Bool = false) -> Attempt {
        let pkce = PKCE.generate()
        let state = PKCE.randomString(bytes: 24)
        var components = URLComponents(url: baseURL.appending(path: "auth/app/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "device", value: String(deviceName.prefix(60))),
        ] + (chooseAccount ? [URLQueryItem(name: "prompt", value: "login")] : [])
        return Attempt(pkce: pkce, state: state, url: components.url!)
    }

    /// El código de la vuelta, si es de este intento.
    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard callback.scheme == callbackScheme, value("state") == expectedState else { throw AppLoginError.stateMismatch }
        if let error = value("error") { throw AppLoginError.server(code: error) }
        guard let code = value("code"), !code.isEmpty else { throw AppLoginError.missingCode }
        return code
    }

    public func redeem(code: String, verifier: String) async throws -> AppLoginResult {
        let request = Self.makeRedeemRequest(baseURL: baseURL, code: code, verifier: verifier)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppLoginError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AppLoginError.invalidResponse }
        guard http.statusCode == 200 else { throw AppLoginError.rejected(status: http.statusCode) }
        guard let result = try? JSONDecoder().decode(AppLoginResult.self, from: data) else { throw AppLoginError.invalidResponse }
        return result
    }

    /// Cerrar sesión: el token de dispositivo se revoca a sí mismo. false si no se pudo confirmar.
    public func revoke(token: String) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "v1/device/token"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { $0.statusCode == 204 || $0.statusCode == 401 } ?? false
    }

    public static func makeRedeemRequest(baseURL: URL, code: String, verifier: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "auth/app/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        // URLComponents no escapa "+" ni "&" dentro de valores de formulario: el code y el
        // verifier son base64url (sin esos caracteres), pero por si acaso se escapan.
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return request
    }
}
