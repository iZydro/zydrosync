import Domain
import Foundation

/// Lo que el motor necesita de HealthKit. La app lo implementa con HealthKitReader; los tests,
/// con un fake. SyncCore no importa HealthKit.
public protocol WorkoutSource: Sendable {
    /// Carreras nuevas desde el ancla, YA filtradas por origen, y el ancla nueva.
    func newWorkouts(after anchor: Data?) async throws -> (workouts: [WorkoutHeader], anchor: Data)
    func rawWorkout(id: UUID) async throws -> RawWorkout
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

        public init() {}
    }

    private let queue: SyncQueue
    private let source: any WorkoutSource
    private let uploader: any WorkoutUploader
    private let clock: @Sendable () -> Date
    private let config: Config

    private var isRunning = false
    private var rerunRequested = false

    public init(queue: SyncQueue, source: any WorkoutSource, uploader: any WorkoutUploader,
                config: Config = Config(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.source = source
        self.uploader = uploader
        self.config = config
        self.clock = clock
    }

    @discardableResult
    public func sync() async -> SyncReport {
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
