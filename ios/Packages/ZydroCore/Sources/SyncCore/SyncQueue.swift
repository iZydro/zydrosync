import Domain
import Foundation

/// Única dueña del estado persistente. Cada mutación se guarda antes de devolver, así que
/// lo que la cola dice que ha pasado ha pasado también en disco.
///
/// Todas las operaciones reciben `now` explícito: la cola no lee el reloj, lo que hace los
/// tests deterministas y deja la política de tiempo en el motor.
public actor SyncQueue {
    private var manifest: QueueManifest
    private var index: [UUID: Int]
    private let store: any QueueStore
    private let policy: RetryPolicy
    private let random: @Sendable () -> Double
    private let continuation: AsyncStream<QueueSnapshot>.Continuation

    /// Snapshots tras cada cambio (para la UI). Un solo consumidor.
    public nonisolated let updates: AsyncStream<QueueSnapshot>

    public init(store: any QueueStore,
                policy: RetryPolicy = RetryPolicy(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0 ..< 1) }) throws {
        let manifest = try store.load() ?? QueueManifest()
        self.manifest = manifest
        index = Self.buildIndex(manifest.items)
        self.store = store
        self.policy = policy
        self.random = random
        (updates, continuation) = AsyncStream.makeStream(of: QueueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Lectura

    public var anchor: Data? { manifest.anchor }
    public var isAuthPaused: Bool { manifest.authPaused }

    public func item(_ id: UUID) -> QueueItem? {
        index[id].map { manifest.items[$0] }
    }

    public func snapshot() -> QueueSnapshot {
        QueueSnapshot(
            items: manifest.items.sorted { $0.workoutStart > $1.workoutStart },
            authPaused: manifest.authPaused,
            lastSyncAt: manifest.lastSyncAt,
            lastSyncError: manifest.lastSyncError
        )
    }

    /// Siguiente elemento a procesar: pendientes cuyo momento ha llegado; primero `live`,
    /// y dentro de cada prioridad la carrera más reciente (es la que el usuario quiere ver).
    public func nextDue(now: Date, excluding: Set<UUID> = []) -> QueueItem? {
        guard !manifest.authPaused else { return nil }
        return manifest.items
            .filter { $0.status == .pending && $0.nextAttemptAt <= now && !excluding.contains($0.id) }
            .min { a, b in
                a.priority != b.priority ? a.priority < b.priority : a.workoutStart > b.workoutStart
            }
    }

    /// Momento en que habrá algo listo para procesar (el pendiente más próximo), o nil si no
    /// hay nada pendiente o la cola está pausada por el token.
    public func nextWakeDate() -> Date? {
        guard !manifest.authPaused else { return nil }
        return manifest.items.lazy.filter { $0.status == .pending }.map(\.nextAttemptAt).min()
    }

    // MARK: Altas

    /// Fecha de instalación (se fija la primera vez que se pide).
    public func installDate(now: Date) throws -> Date {
        if let date = manifest.installDate { return date }
        manifest.installDate = now
        try persist()
        return now
    }

    /// Encola las carreras nuevas Y avanza el ancla en una sola escritura (ver QueueManifest).
    /// Las que ya estaban en la cola se ignoran (no se resetea una ya enviada).
    @discardableResult
    public func enqueue(_ headers: [WorkoutHeader], priority: WorkoutPriority,
                        advancingAnchorTo anchor: Data?, now: Date) throws -> Int {
        var added = 0
        for header in headers where index[header.id] == nil {
            index[header.id] = manifest.items.count
            manifest.items.append(QueueItem(header: header, priority: priority, now: now))
            added += 1
        }
        if let anchor { manifest.anchor = anchor }
        if added > 0 || anchor != nil { try persist() }
        return added
    }

    // MARK: Resultados

    public func record(_ outcome: UploadOutcome, for id: UUID, payloadBytes: Int?, now: Date) throws {
        try mutate(id) { item in
            item.payloadBytes = payloadBytes ?? item.payloadBytes
            switch outcome {
            case let .success(status):
                item.status = .sent
                item.sentAt = now
                item.lastHTTPStatus = status
                item.lastError = nil
            case let .unauthorized(status):
                // El elemento no ha fallado: se queda pendiente y listo en cuanto haya token.
                item.lastHTTPStatus = status
                item.lastError = "Token rechazado (\(status))"
            case let .permanent(status, message):
                item.status = .failed
                item.lastHTTPStatus = status
                item.lastError = message
            case let .retry(status, after, message):
                item.attempts += 1
                item.lastHTTPStatus = status
                item.lastError = message
                let backoff = policy.delay(afterAttempt: item.attempts, random: random())
                let delay = after.map { min(max($0, 1), policy.cap) } ?? backoff
                item.nextAttemptAt = now.addingTimeInterval(delay)
            }
        }
        if case .unauthorized = outcome {
            manifest.authPaused = true
            try persist()
        }
    }

    /// Aplaza sin contar un intento (bloqueado, esperando la ruta, periodo de asentamiento).
    public func postpone(_ id: UUID, until date: Date, reason: String) throws {
        try mutate(id) { item in
            item.nextAttemptAt = date
            item.lastError = reason
        }
    }

    public func markFailed(_ id: UUID, reason: String) throws {
        try mutate(id) { item in
            item.status = .failed
            item.lastError = reason
        }
    }

    // MARK: Acciones del usuario

    /// Reintento manual: vuelve a pendiente, ya, con el contador a cero.
    public func retry(_ id: UUID, now: Date) throws {
        try mutate(id) { item in
            guard item.status != .sent else { return }
            item.status = .pending
            item.attempts = 0
            item.nextAttemptAt = now
        }
    }

    public func retryAllFailed(now: Date) throws {
        for i in manifest.items.indices where manifest.items[i].status == .failed {
            manifest.items[i].status = .pending
            manifest.items[i].attempts = 0
            manifest.items[i].nextAttemptAt = now
        }
        try persist()
    }

    /// Olvida las carreras enviadas y reinicia el ancla de HealthKit, en una sola escritura.
    ///
    /// Solo quitarlas de la cola no bastaría: el ancla ya las ha dejado atrás y nunca
    /// volverían. Con el ancla a cero, la siguiente sincronización las redescubre y las envía
    /// otra vez (respetando el corte de la primera ejecución; las más antiguas son cosa de la
    /// importación del histórico). Para el servidor es un reenvío idempotente.
    /// Útil al cambiar de servidor. Las pendientes y las de error se conservan.
    @discardableResult
    public func forgetSentAndRediscover() throws -> Int {
        let before = manifest.items.count
        manifest.items.removeAll { $0.status == .sent }
        manifest.anchor = nil
        index = Self.buildIndex(manifest.items)
        try persist()
        return before - manifest.items.count
    }

    /// Tras cambiar el token: se reanuda y todo lo pendiente pasa a estar listo ya.
    public func resumeAfterCredentialsChange(now: Date) throws {
        manifest.authPaused = false
        for i in manifest.items.indices where manifest.items[i].status == .pending {
            manifest.items[i].nextAttemptAt = now
        }
        try persist()
    }

    public func recordSync(at date: Date, error: String?) throws {
        manifest.lastSyncAt = date
        manifest.lastSyncError = error
        try persist()
    }

    // MARK: Internos

    private func mutate(_ id: UUID, _ change: (inout QueueItem) -> Void) throws {
        guard let i = index[id] else { return }
        change(&manifest.items[i])
        try persist()
    }

    private func persist() throws {
        try store.save(manifest)
        continuation.yield(snapshot())
    }

    private static func buildIndex(_ items: [QueueItem]) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
    }
}
