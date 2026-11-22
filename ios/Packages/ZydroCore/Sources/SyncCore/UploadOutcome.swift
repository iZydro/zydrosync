import Foundation

/// Resultado de un envío, ya interpretado. Es la frontera entre el transporte (HTTP) y la
/// cola: la cola no sabe nada de códigos de estado, y otro backend solo tiene que producir
/// estos casos.
public enum UploadOutcome: Sendable, Equatable {
    /// 2xx. 201 = creada, 200 = ya existía (reenvío idempotente).
    case success(status: Int)
    /// 401/403: se pausa toda la cola hasta que cambie el token.
    case unauthorized(status: Int)
    /// 4xx no transitorio (400, 404, 409, 413, 415, 422…): reintentar no lo arreglará.
    case permanent(status: Int?, message: String)
    /// Red, 5xx, 408, 425, 429. `after` viene de Retry-After si el servidor lo mandó.
    case retry(status: Int?, after: TimeInterval?, message: String)

    public static func classify(status: Int, retryAfter: String?, body: Data?, now: Date) -> UploadOutcome {
        let message = problemMessage(body) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 200 ..< 300:
            return .success(status: status)
        case 401, 403:
            return .unauthorized(status: status)
        case 408, 425, 429, 500 ..< 600:
            return .retry(status: status, after: parseRetryAfter(retryAfter, now: now), message: "\(status) \(message)")
        default:
            return .permanent(status: status, message: "\(status) \(message)")
        }
    }

    /// Errores de URLSession. Solo los que indican una URL mal formada son permanentes; el
    /// resto (sin red, timeout, DNS, TLS…) se reintenta.
    public static func classify(error: any Error) -> UploadOutcome {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return .permanent(status: nil, message: "URL no válida: \(urlError.localizedDescription)")
            case .cancelled:
                return .retry(status: nil, after: nil, message: "Envío cancelado")
            default:
                return .retry(status: nil, after: nil, message: urlError.localizedDescription)
            }
        }
        return .retry(status: nil, after: nil, message: error.localizedDescription)
    }

    /// RFC 9110: segundos enteros o fecha HTTP (IMF-fixdate).
    public static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return TimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// RFC 9457 (application/problem+json): usa `detail` o `title` si vienen.
    static func problemMessage(_ body: Data?) -> String? {
        guard let body, !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let text = (object["detail"] as? String) ?? (object["title"] as? String)
        return text.map { String($0.prefix(300)) }
    }
}

public protocol WorkoutUploader: Sendable {
    /// false si falta URL o token: la sincronización descubre y encola, pero no envía.
    func isConfigured() async -> Bool
    func upload(workoutID: UUID, gzippedJSON: Data) async -> UploadOutcome
}
