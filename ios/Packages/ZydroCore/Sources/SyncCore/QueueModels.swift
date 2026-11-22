import Domain
import Foundation

public enum WorkoutPriority: Int, Codable, Sendable, Comparable {
    /// Descubierta por la sincronización normal.
    case live = 0
    /// Importación de histórico (fase e): solo se envía cuando no queda nada `live`.
    case historic = 1

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct QueueItem: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        /// Pendiente de enviar (primera vez o reintento). Ver `nextAttemptAt`.
        case pending
        case sent
        /// Error permanente: no se reintenta solo. El usuario puede reintentarlo a mano.
        case failed
    }

    public let id: UUID
    public var priority: WorkoutPriority
    public var workoutStart: Date
    public var workoutEnd: Date
    public var distanceMeters: Double?
    public var discoveredAt: Date
    public var status: Status
    /// Intentos de envío fallidos. Los aplazamientos (dispositivo bloqueado, esperando la
    /// ruta) no cuentan: no son fallos y no deben inflar el backoff.
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public var lastHTTPStatus: Int?
    public var sentAt: Date?
    public var payloadBytes: Int?

    public init(header: WorkoutHeader, priority: WorkoutPriority, now: Date) {
        id = header.id
        self.priority = priority
        workoutStart = header.startDate
        workoutEnd = header.endDate
        distanceMeters = header.distanceMeters
        discoveredAt = now
        status = .pending
        attempts = 0
        nextAttemptAt = now
    }
}

/// Todo el estado persistente de la sincronización, en un único fichero.
///
/// El ancla de HealthKit vive aquí, junto a la cola, a propósito: encolar los UUID nuevos y
/// avanzar el ancla es UNA sola escritura atómica. Si fueran dos ficheros, un cierre de la
/// app entre ambas escrituras podría avanzar el ancla sin haber encolado (carrera perdida
/// para siempre) o al revés (inofensivo, pero solo por suerte).
public struct QueueManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int = Self.currentVersion
    public var items: [QueueItem] = []
    public var anchor: Data?
    /// Primera ejecución: las carreras anteriores (menos un margen) son "histórico" y no se
    /// envían solas. Evita que la primera sincronización mande años de carreras.
    public var installDate: Date?
    /// 401/403: no tiene sentido seguir enviando hasta que cambie el token.
    public var authPaused: Bool = false
    public var lastSyncAt: Date?
    public var lastSyncError: String?

    public init() {}
}

public struct QueueSnapshot: Sendable, Equatable {
    public var items: [QueueItem]
    public var authPaused: Bool
    public var lastSyncAt: Date?
    public var lastSyncError: String?

    public var pendingCount: Int { items.count { $0.status == .pending } }
    public var sentCount: Int { items.count { $0.status == .sent } }
    public var failedCount: Int { items.count { $0.status == .failed } }

    public static let empty = QueueSnapshot(items: [], authPaused: false)

    public init(items: [QueueItem], authPaused: Bool, lastSyncAt: Date? = nil, lastSyncError: String? = nil) {
        self.items = items
        self.authPaused = authPaused
        self.lastSyncAt = lastSyncAt
        self.lastSyncError = lastSyncError
    }
}
