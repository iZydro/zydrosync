import Foundation
import Transport

/// URL en UserDefaults (no es secreta); token en el Keychain.
enum BackendSettings {
    static let endpointKey = "endpointURL"
    static let defaultEndpoint = "https://sync.isidrogilabert.com/v1/workouts"
    static let loggedInEmailKey = "loggedInEmail"
    static let tokenStore = KeychainTokenStore()

    static var endpointText: String {
        get { UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint }
        set { UserDefaults.standard.set(newValue, forKey: endpointKey) }
    }

    /// Con quién se entró con ZydroLogin (no es secreto; el token va al Keychain).
    static var loggedInEmail: String? {
        get { UserDefaults.standard.string(forKey: loggedInEmailKey) }
        set { UserDefaults.standard.set(newValue, forKey: loggedInEmailKey) }
    }

    static var hasToken: Bool {
        ((try? tokenStore.read()) ?? nil)?.isEmpty == false
    }

    /// nil si falta algo: el motor descubre y encola pero no envía.
    static func credentials() -> BackendCredentials? {
        guard let url = URL(string: endpointText.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil,
              let token = (try? tokenStore.read()) ?? nil, !token.isEmpty
        else { return nil }
        return BackendCredentials(endpoint: url, token: token)
    }

    static var clientVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
