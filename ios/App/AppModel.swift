import Domain
import Foundation
import HealthReading
import Observation
import SyncCore
import Transport
import UIKit

struct PayloadExport: Sendable {
    let url: URL
    let jsonBytes: Int
    let gzipBytes: Int
    let encodeTime: Duration
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    // MARK: Salud (fase a)

    private(set) var isHealthAvailable = HealthKitReader.isHealthDataAvailable
    private(set) var authState: AuthorizationRequestState?
    private(set) var workouts: [DiscoveredWorkout] = []
    private(set) var phase: Phase = .idle
    private(set) var isProtectedDataAvailable = UIApplication.shared.isProtectedDataAvailable

    // MARK: Sincronización (fase c)

    private(set) var queueSnapshot = QueueSnapshot.empty
    private(set) var lastReport: SyncReport?
    private(set) var isSyncing = false
    private(set) var setupError: String?
    private(set) var hasToken = BackendSettings.hasToken
    var endpointText = BackendSettings.endpointText
    /// La URL que de verdad usa el envío (la guardada), que puede no ser la del campo.
    private(set) var savedEndpoint = BackendSettings.endpointText
    /// Nunca se rellena con el token guardado: solo sirve para escribir uno nuevo.
    var tokenText = ""

    let reader = HealthKitReader()
    private let queue: SyncQueue?
    private let engine: SyncEngine?

    init() {
        let reader = self.reader
        do {
            let queue = try SyncQueue(store: FileQueueStore(url: FileQueueStore.defaultURL()))
            let uploader = HTTPWorkoutUploader(clientVersion: BackendSettings.clientVersion) {
                BackendSettings.credentials()
            }
            self.queue = queue
            engine = SyncEngine(queue: queue, source: HealthKitWorkoutSource(reader: reader), uploader: uploader)
            Task { [weak self] in
                await self?.setSnapshot(queue.snapshot())
                for await snapshot in queue.updates {
                    self?.setSnapshot(snapshot)
                }
            }
        } catch {
            queue = nil
            engine = nil
            setupError = "No se pudo abrir la cola: \(error)"
        }
    }

    private func setSnapshot(_ snapshot: QueueSnapshot) {
        queueSnapshot = snapshot
    }

    // MARK: Acciones

    func refresh() async {
        guard isHealthAvailable else { return }
        phase = .loading
        do {
            authState = try await reader.authorizationRequestState()
            workouts = try await reader.recentRunningWorkouts(limit: 50)
            phase = .idle
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    func requestAuthorization() async {
        do {
            try await reader.requestAuthorization()
        } catch {
            phase = .failed(Self.describe(error))
        }
        await refresh()
        await syncNow()
    }

    func syncNow() async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        lastReport = await engine.sync()
        isSyncing = false
        await scheduleWake()
    }

    // MARK: Reintentos con la app en primer plano

    private var isActive = false
    private var wakeTask: Task<Void, Never>?

    /// Con la app abierta, cada sincronización deja programado un despertar para cuando toque
    /// el siguiente reintento o aplazamiento. Al pasar a segundo plano se cancela: fuera de
    /// primer plano, el trabajo es de HKObserverQuery y BGTaskScheduler (fase d).
    func setActive(_ active: Bool) {
        isActive = active
        if active {
            Task { await syncNow() }
        } else {
            wakeTask?.cancel()
            wakeTask = nil
        }
    }

    private func scheduleWake() async {
        wakeTask?.cancel()
        wakeTask = nil
        // Si la pasada se paró (bloqueado, sin configurar, token rechazado), reintentar a
        // ciegas sería un bucle: esos casos se reanudan con su propio evento (desbloqueo,
        // guardar ajustes).
        guard isActive, lastReport?.stoppedBecause == nil,
              let date = await queue?.nextWakeDate() else { return }
        // Mínimo 5 s: si algo quedara "vencido" sin poder procesarse, no se convierte en un
        // bucle que consulte HealthKit cada segundo.
        let delay = max(5, date.timeIntervalSinceNow + 0.5)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func saveSettings() async {
        BackendSettings.endpointText = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        savedEndpoint = BackendSettings.endpointText
        endpointText = savedEndpoint
        if !tokenText.isEmpty {
            do {
                try BackendSettings.tokenStore.write(tokenText)
                tokenText = ""
            } catch {
                setupError = "No se pudo guardar el token en el Keychain: \(error)"
            }
        }
        hasToken = BackendSettings.hasToken
        try? await queue?.resumeAfterCredentialsChange(now: Date())
        await syncNow()
    }

    var hasUnsavedSettings: Bool {
        endpointText.trimmingCharacters(in: .whitespacesAndNewlines) != savedEndpoint || !tokenText.isEmpty
    }

    func deleteToken() {
        try? BackendSettings.tokenStore.write(nil)
        hasToken = false
    }

    func retry(_ id: UUID) async {
        try? await queue?.retry(id, now: Date())
        await syncNow()
    }

    func retryAllFailed() async {
        try? await queue?.retryAllFailed(now: Date())
        await syncNow()
    }

    /// Olvida las enviadas y reinicia el ancla: se redescubren y se reenvían (ver SyncQueue).
    func forgetSentAndResend() async {
        do {
            try await queue?.forgetSentAndRediscover()
        } catch {
            setupError = "No se pudo vaciar la cola: \(error)"
        }
        await syncNow()
    }

    func read(_ id: UUID) async throws -> RawWorkout {
        try await reader.readWorkout(id: id)
    }

    /// Fase (b): genera el payload, lo comprime para medir y deja el JSON legible en un
    /// fichero temporal para compartirlo. Fuera del MainActor: una ruta larga son ~100 ms.
    nonisolated static func export(_ raw: RawWorkout) async throws -> PayloadExport {
        try await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            let payload = WorkoutMapper.payload(from: raw)
            let json = try PayloadEncoding.json(payload)
            let gzip = try Gzip.compress(json)
            let elapsed = clock.now - start
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("zydro-\(raw.header.id.uuidString).json")
            try json.write(to: url, options: .atomic)
            return PayloadExport(url: url, jsonBytes: json.count, gzipBytes: gzip.count, encodeTime: elapsed)
        }.value
    }

    /// Llamado desde la vista con las notificaciones protectedData{Did,Will}… de UIApplication.
    func protectedDataChanged(available: Bool) {
        isProtectedDataAvailable = available
        if available {
            Task {
                await refresh()
                await syncNow()
            }
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error as? HealthReadingError {
        case .protectedDataUnavailable: "Salud no accesible: dispositivo bloqueado"
        case .healthDataUnavailable: "HealthKit no disponible en este dispositivo"
        case .workoutNotFound: "El entrenamiento ya no existe en Salud"
        case .invalidAnchor: "Ancla corrupta"
        case let .underlying(message): message
        case nil: error.localizedDescription
        }
    }
}
