import Domain
import Foundation

/// Lo que el motor necesita de HealthKit. La app lo implementa con HealthKitReader; los tests,
/// con un fake. SyncCore no importa HealthKit.
public protocol WorkoutSource: Sendable {
    /// Carreras nuevas desde el ancla, YA filtradas por origen, y el ancla nueva.
    func newWorkouts(after anchor: Data?) async throws -> (workouts: [WorkoutHeader], anchor: Data)
    func rawWorkout(id: UUID) async throws -> RawWorkout
    /// Carreras que empezaron en [desde, hasta), YA filtradas por origen. Para el histórico.
    func workouts(from start: Date, to end: Date) async throws -> [WorkoutHeader]
}

/// Lo que hay en el servidor. Solo los identificadores: es lo que necesita la reconciliación.
public protocol ServerCatalog: Sendable {
    func workoutIDs() async -> CatalogResult
}

public enum CatalogResult: Sendable, Equatable {
    case ids(Set<UUID>)
    case unauthorized(status: Int)
    case failure(String)
}

public enum WorkoutSourceError: Error, Sendable, Equatable {
    /// Datos de Salud cifrados (iPhone bloqueado). No es un fallo: se reintenta al desbloquear.
    case locked
    /// Borrada de Salud entre el descubrimiento y el envío.
    case notFound
    case other(String)
}

public struct SyncReport: Sendable, Equatable {
    public var discovered = 0
    public var sent = 0
    public var failed = 0
    public var retrying = 0
    public var postponed = 0
    public var stoppedBecause: StopReason?
    /// Resultado de la comparación con el servidor, si se hizo en esta pasada.
    public var reconcile: ReconcileResult?
    public var reconcileError: String?

    public enum StopReason: String, Sendable, Equatable {
        case locked = "Salud bloqueado (iPhone bloqueado)"
        case notConfigured = "Falta URL o token"
        case unauthorized = "Token rechazado por el servidor"
        case alreadyRunning = "Ya había una sincronización en curso"
        case cancelled = "Cancelada"
    }

    public init() {}
}

/// Orquesta una pasada de sincronización:
///  1. descubrir carreras nuevas (consulta anclada) → encolar + avanzar ancla (atómico);
///  2. vaciar la cola: por cada elemento listo, leer de Salud, mapear, comprimir y enviar.
///
/// Serie, de uno en uno: el cuello de botella es la red y así el servidor nunca recibe
/// ráfagas. Si llega otra petición de sincronizar mientras corre (p. ej. el observer de
/// HealthKit en la fase d), no se lanza otra en paralelo: se marca y se repite al terminar.
public actor SyncEngine {
    public struct Config: Sendable {
        /// El Watch sincroniza el HKWorkout antes que todas sus muestras y la ruta:
        /// se espera esto desde que se descubre la carrera antes de construir el payload.
        public var settleDelay: TimeInterval = 120
        /// Carrera al aire libre sin ruta: si terminó hace menos de esto, se espera a la ruta.
        public var missingRouteGrace: TimeInterval = 3600
        public var missingRouteRecheck: TimeInterval = 300
        /// Las carreras que empezaron antes de (instalación − esto) son histórico.
        public var firstRunLookback: TimeInterval = 48 * 3600
        /// Cada cuánto se compara la cola con el servidor por sí sola.
        public var reconcileInterval: TimeInterval = 24 * 3600

        public init() {}
    }

    private let queue: SyncQueue
    private let source: any WorkoutSource
    private let uploader: any WorkoutUploader
    private let catalog: (any ServerCatalog)?
    private let clock: @Sendable () -> Date
    private let config: Config

    private var isRunning = false
    private var rerunRequested = false
    private var reconcileRequested = false

    public init(queue: SyncQueue, source: any WorkoutSource, uploader: any WorkoutUploader,
                catalog: (any ServerCatalog)? = nil,
                config: Config = Config(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.source = source
        self.uploader = uploader
        self.catalog = catalog
        self.config = config
        self.clock = clock
    }

    /// `reconcile`: comparar con el servidor en esta pasada aunque no toque (botón
    /// "Comprobar con el servidor", importación del histórico).
    @discardableResult
    public func sync(reconcile: Bool = false) async -> SyncReport {
        if reconcile { reconcileRequested = true }
        if isRunning {
            rerunRequested = true
            var report = SyncReport()
            report.stoppedBecause = .alreadyRunning
            return report
        }
        isRunning = true
        defer { isRunning = false }

        var report = SyncReport()
        repeat {
            rerunRequested = false
            await pass(into: &report)
        } while rerunRequested && report.stoppedBecause == nil

        try? await queue.recordSync(at: clock(), error: report.stoppedBecause?.rawValue)
        return report
    }

    // MARK: Histórico

    public struct HistoryImport: Sendable, Equatable {
        public var found: Int
        public var added: Int
    }

    /// Encola las carreras del Watch desde `since` (hasta hace una hora, para no pisar una
    /// recién terminada que aún está llegando). Después, quien llama lanza
    /// `sync(reconcile: true)`: la pasada compara antes con el servidor, y lo que ya tiene no
    /// se vuelve a subir.
    public func importHistory(since: Date) async throws -> HistoryImport {
        let now = clock()
        let headers = try await source.workouts(from: since, to: now.addingTimeInterval(-config.missingRouteGrace))
        let added = try await queue.enqueueHistoric(headers, since: since, now: now)
        return HistoryImport(found: headers.count, added: added)
    }

    // MARK: Pasada

    private func pass(into report: inout SyncReport) async {
        // 1. Descubrir
        do {
            let installDate = try await queue.installDate(now: clock())
            let cutoff = installDate.addingTimeInterval(-config.firstRunLookback)
            let (workouts, anchor) = try await source.newWorkouts(after: await queue.anchor)
            let live = workouts.filter { $0.startDate >= cutoff }
            report.discovered += try await queue.enqueue(live, priority: .live, advancingAnchorTo: anchor, now: clock())
        } catch WorkoutSourceError.locked {
            report.stoppedBecause = .locked
            return
        } catch {
            // Si falla el descubrimiento, aún se puede vaciar lo que ya estaba encolado.
        }

        // 2. Vaciar
        guard await uploader.isConfigured() else {
            report.stoppedBecause = .notConfigured
            return
        }

        // Comparar con el servidor antes de enviar: lo que ya tiene no se sube otra vez, y
        // lo que falta se marca (sin reenviarlo).
        if await shouldReconcile() {
            reconcileRequested = false
            switch await catalog?.workoutIDs() {
            case let .ids(ids):
                do {
                    report.reconcile = try await queue.reconcile(serverIDs: ids, now: clock())
                } catch {
                    report.reconcileError = "\(error)"
                }
            case .unauthorized:
                report.reconcileError = "Token rechazado al leer la lista del servidor"
            case let .failure(message):
                report.reconcileError = message
            case nil:
                break
            }
        }
        var visited = Set<UUID>()
        while let item = await queue.nextDue(now: clock(), excluding: visited) {
            if Task.isCancelled {
                report.stoppedBecause = .cancelled
                return
            }
            visited.insert(item.id)
            if let stop = await process(item, report: &report) {
                report.stoppedBecause = stop
                return
            }
        }
    }

    private func shouldReconcile() async -> Bool {
        guard catalog != nil, !(await queue.isAuthPaused) else { return false }
        if reconcileRequested { return true }
        guard let last = await queue.lastReconciledAt else { return true }
        return clock().timeIntervalSince(last) >= config.reconcileInterval
    }

    private func process(_ item: QueueItem, report: inout SyncReport) async -> SyncReport.StopReason? {
        let now = clock()
        do {
            let settledAt = item.discoveredAt.addingTimeInterval(config.settleDelay)
            let recentlyFinished = now.timeIntervalSince(item.workoutEnd) < config.missingRouteGrace
            if item.priority == .live, recentlyFinished, now < settledAt {
                try await queue.postpone(item.id, until: settledAt, reason: "Esperando a que el reloj termine de sincronizar")
                report.postponed += 1
                return nil
            }

            let raw: RawWorkout
            do {
                raw = try await source.rawWorkout(id: item.id)
            } catch WorkoutSourceError.locked {
                return .locked
            } catch WorkoutSourceError.notFound {
                try await queue.markFailed(item.id, reason: "Ya no está en Salud")
                report.failed += 1
                return nil
            }

            if !raw.header.isIndoor, raw.routePointCount == 0,
               now.timeIntervalSince(raw.header.endDate) < config.missingRouteGrace {
                try await queue.postpone(item.id, until: now.addingTimeInterval(config.missingRouteRecheck),
                                         reason: "Esperando la ruta GPS del reloj")
                report.postponed += 1
                return nil
            }

            let body: Data
            do {
                body = try PayloadEncoding.gzippedJSON(WorkoutMapper.payload(from: raw))
            } catch {
                try await queue.markFailed(item.id, reason: "No se pudo generar el JSON: \(error)")
                report.failed += 1
                return nil
            }

            let outcome = await uploader.upload(workoutID: item.id, gzippedJSON: body)
            try await queue.record(outcome, for: item.id, payloadBytes: body.count, now: clock())
            switch outcome {
            case .success: report.sent += 1
            case .permanent: report.failed += 1
            case .retry: report.retrying += 1
            case .unauthorized: return .unauthorized
            }
            return nil
        } catch {
            // Error de la propia fuente (no bloqueo) o de persistencia: se trata como transitorio.
            try? await queue.record(.retry(status: nil, after: nil, message: "\(error)"), for: item.id,
                                    payloadBytes: nil, now: clock())
            report.retrying += 1
            return nil
        }
    }
}
