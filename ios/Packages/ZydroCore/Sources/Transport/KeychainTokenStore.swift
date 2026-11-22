import Foundation
import Security

/// Token Bearer en el Keychain (nunca en UserDefaults).
///
/// `AfterFirstUnlockThisDeviceOnly`:
/// - AfterFirstUnlock: se puede leer con el iPhone bloqueado (tras el primer desbloqueo
///   desde el arranque), necesario para enviar en background con la pantalla apagada.
/// - ThisDeviceOnly: no viaja en copias de seguridad ni a otro dispositivo.
///
/// Las funciones SecItem* son seguras entre hilos, así que el tipo puede ser Sendable sin estado.
public struct KeychainTokenStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    private let service: String
    private let account: String

    public init(service: String = "com.zydrotrack.sync", account: String = "api-token") {
        self.service = service
        self.account = account
    }

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw Error.unexpectedStatus(status)
        }
    }

    /// nil o cadena vacía borran el token.
    public func write(_ token: String?) throws {
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.unexpectedStatus(status) }
            return
        }
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attributes) { $1 }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw Error.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
