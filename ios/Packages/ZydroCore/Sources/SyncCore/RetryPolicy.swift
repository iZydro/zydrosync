import Foundation

/// Backoff exponencial con "equal jitter": la mitad del retraso es fija y la otra mitad
/// aleatoria.
///
/// No se usa "full jitter" (0…d) porque puede dar retrasos de casi cero y, con un único
/// cliente, el problema no es la estampida contra el servidor sino no machacar la batería
/// reintentando en bucle. Con base 30 s y tope 6 h: 15–30 s, 30–60 s, 1–2 min… y a partir
/// del 11.º intento, 3–6 h. Sin límite de intentos: una carrera nunca se da por perdida
/// por problemas de red; solo los errores permanentes (4xx) la paran.
public struct RetryPolicy: Sendable, Equatable {
    public var base: TimeInterval
    public var cap: TimeInterval

    public init(base: TimeInterval = 30, cap: TimeInterval = 6 * 3600) {
        self.base = base
        self.cap = cap
    }

    /// - Parameter attempt: número de fallos acumulados (1 = primer fallo).
    /// - Parameter random: valor en [0, 1).
    public func delay(afterAttempt attempt: Int, random: Double) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        // min antes de pow para no desbordar con muchos intentos.
        let ceiling = min(cap, base * pow(2, min(exponent, 30)))
        return ceiling / 2 + ceiling / 2 * min(max(random, 0), 1)
    }
}
