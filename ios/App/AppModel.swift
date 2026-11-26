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
    /// Carrera más antigua en Salud: inicio propuesto para el histórico.
    private(set) var oldestWorkoutStart: Date?
    /// Resultado de la última acción del histórico o de la comprobación con el servidor.
    private(set) var historyMessage: String?
    /// Cuenta con la que se entró con ZydroLogin (nil: token manual o sin sesión).
    private(set) var loggedInEmail = BackendSettings.loggedInEmail
    private(set) var loginMessage: String?
    private(set) var isLoggingIn = false
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
            let catalog = HTTPServerCatalog(clientVersion: BackendSettings.clientVersion) {
                BackendSettings.credentials()
            }
            self.queue = queue
            engine = SyncEngine(queue: queue, source: HealthKitWorkoutSource(reader: reader), uploader: uploader,
                                catalog: catalog)
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
            oldestWorkoutStart = try await reader.oldestRunningWorkoutStart()
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

    /// `manual`: lo ha pedido el usuario, así que los reintentos programados para más tarde
    /// se adelantan. `reconcile`: comparar con el servidor aunque no toque.
    func syncNow(manual: Bool = false, reconcile: Bool = false) async {
        guard let engine else { return }
        if manual { try? await queue?.expedite(now: Date()) }
        // Si ya hay una pasada, el motor la repite al terminar (y respeta `reconcile`).
        guard !isSyncing else {
            await engine.sync(reconcile: reconcile)
            return
        }
        isSyncing = true
        let report = await engine.sync(reconcile: reconcile)
        lastReport = report
        isSyncing = false
        if reconcile { historyMessage = Self.describe(report.reconcile, error: report.reconcileError) }
        await scheduleWake()
    }

    // MARK: Servidor e histórico

    func checkWithServer() async {
        await syncNow(manual: true, reconcile: true)
    }

    func importHistory(since: Date) async {
        guard let engine else { return }
        do {
            let result = try await engine.importHistory(since: since)
            historyMessage = result.found == 0
                ? "No hay carreras del Apple Watch desde esa fecha."
                : "\(result.found) carreras del Apple Watch desde esa fecha; \(result.added) añadidas a la cola. Las que ya estén en el servidor no se vuelven a subir."
        } catch {
            historyMessage = "No se pudo leer el histórico: \(Self.describe(error))"
            return
        }
        await syncNow(reconcile: true)
    }

    func cancelHistoryImport() async {
        let removed = (try? await queue?.cancelHistoricImport()) ?? 0
        historyMessage = "Importación cancelada: \(removed) carreras quitadas de la cola. Las ya enviadas siguen en el servidor."
    }

    /// Volver a enviar una carrera. Si no estaba en la cola (anterior a la instalación y sin
    /// importar), se añade como histórico.
    func resend(_ header: WorkoutHeader) async {
        guard let queue else { return }
        _ = try? await queue.enqueue([header], priority: .historic, advancingAnchorTo: nil, now: Date())
        try? await queue.resend([header.id], now: Date())
        await syncNow(manual: true)
    }

    func resend(_ id: UUID) async {
        try? await queue?.resend([id], now: Date())
        await syncNow(manual: true)
    }

    func resendAllMissing() async {
        try? await queue?.resendAllMissing(now: Date())
        await syncNow(manual: true)
    }

    private static func describe(_ result: ReconcileResult?, error: String?) -> String? {
        if let error { return "No se pudo comprobar con el servidor: \(error)" }
        guard let result else { return nil }
        var parts: [String] = []
        if result.nowMissing > 0 { parts.append("\(result.nowMissing) ya no están en el servidor") }
        if result.alreadyOnServer > 0 { parts.append("\(result.alreadyOnServer) ya estaban y no se suben") }
        if result.reappeared > 0 { parts.append("\(result.reappeared) vuelven a estar") }
        return parts.isEmpty ? "Comprobado: la app y el servidor coinciden." : "Comprobado: " + parts.joined(separator: "; ") + "."
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
                // Token pegado a mano: ya no es la sesión de ZydroLogin.
                BackendSettings.loggedInEmail = nil
                loggedInEmail = nil
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
        BackendSettings.loggedInEmail = nil
        loggedInEmail = nil
    }

    // MARK: ZydroLogin

    /// Cliente de login para el servidor configurado (por defecto, sync.isidrogilabert.com).
    private func loginClient() -> AppLoginClient? {
        guard let endpoint = URL(string: savedEndpoint), let origin = AppLoginClient.origin(of: endpoint) else { return nil }
        return AppLoginClient(baseURL: origin)
    }

    /// Paso 1: la URL que la vista abre en ASWebAuthenticationSession.
    func beginLogin(chooseAccount: Bool) -> AppLoginClient.Attempt? {
        guard let client = loginClient() else {
            loginMessage = "La URL del servidor no es válida."
            return nil
        }
        loginMessage = nil
        isLoggingIn = true
        return client.begin(deviceName: UIDevice.current.name, chooseAccount: chooseAccount)
    }

    /// Paso 2: la vuelta zydrosync://auth → canje → token de dispositivo al Keychain.
    func completeLogin(callback: URL, attempt: AppLoginClient.Attempt) async {
        defer { isLoggingIn = false }
        guard let client = loginClient() else { return }
        do {
            let code = try AppLoginClient.code(from: callback, expectedState: attempt.state)
            let result = try await client.redeem(code: code, verifier: attempt.pkce.verifier)
            try BackendSettings.tokenStore.write(result.token)
            BackendSettings.endpointText = result.uploadUrl.absoluteString
            BackendSettings.loggedInEmail = result.email
            savedEndpoint = BackendSettings.endpointText
            endpointText = savedEndpoint
            tokenText = ""
            hasToken = true
            loggedInEmail = result.email
            loginMessage = nil
            try? await queue?.resumeAfterCredentialsChange(now: Date())
            await syncNow(manual: true)
        } catch {
            loginMessage = Self.describeLogin(error)
        }
    }

    func loginCancelled(_ message: String?) {
        isLoggingIn = false
        loginMessage = message
    }

    /// Cerrar sesión: revoca el token de dispositivo en el servidor y lo borra del iPhone. La
    /// cola se queda (se reanuda al volver a entrar).
    func signOut() async {
        if let token = (try? BackendSettings.tokenStore.read()) ?? nil, let client = loginClient() {
            let revoked = await client.revoke(token: token)
            loginMessage = revoked ? "Sesión cerrada: el token de este iPhone está revocado."
                : "Sesión cerrada en el iPhone, pero no se pudo confirmar la revocación en el servidor (revísalo en el panel)."
        }
        deleteToken()
    }

    nonisolated static func describeLogin(_ error: any Error) -> String {
        switch error as? AppLoginError {
        case .server("no_account"): "Tu cuenta de Google no tiene usuario en ZydroSync."
        case .server("access_denied"): "ZydroLogin no ha autorizado el acceso."
        case .server("unavailable"): "ZydroLogin no responde ahora mismo. Inténtalo en un momento."
        case .server("account_linked_elsewhere"): "Ese email ya está vinculado a otra cuenta de Google."
        case let .server(code): "No se pudo entrar (\(code))."
        case .stateMismatch: "La respuesta del login no corresponde a este intento. Vuelve a intentarlo."
        case .rejected: "El servidor rechazó el inicio de sesión (¿caducó?). Vuelve a intentarlo."
        case let .network(message): "Sin conexión con el servidor: \(message)"
        case .missingCode, .invalidResponse: "Respuesta inesperada del servidor."
        case nil: error.localizedDescription
        }
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
