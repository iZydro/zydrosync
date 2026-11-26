import AuthenticationServices
import SwiftUI
import SyncCore
import Transport

struct ServerSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var confirmDeleteToken = false
    @State private var confirmSignOut = false
    @State private var showManual = false

    var body: some View {
        @Bindable var model = model
        Section {
            if let email = model.loggedInEmail, model.hasToken {
                LabeledContent("Conectado como") { Text(email).font(.footnote) }
                Button("Cerrar sesión", role: .destructive) { confirmSignOut = true }
                    .confirmationDialog("¿Cerrar sesión en este iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Cerrar sesión", role: .destructive) { Task { await model.signOut() } }
                    } message: {
                        Text("Se revoca el token de este iPhone y deja de enviar carreras hasta que vuelvas a entrar. Lo pendiente se queda en la cola.")
                    }
            } else {
                Button {
                    Task { await signIn(chooseAccount: false) }
                } label: {
                    HStack {
                        Label("Entrar con ZydroLogin", systemImage: "person.badge.key")
                        if model.isLoggingIn {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isLoggingIn)
                Button("Entrar con otra cuenta") { Task { await signIn(chooseAccount: true) } }
                    .disabled(model.isLoggingIn)
            }
            if let message = model.loginMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            DisclosureGroup("Servidor y token manual", isExpanded: $showManual) {
                TextField("https://…/v1/workouts", text: $model.endpointText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await model.saveSettings() } }
                    .font(.footnote.monospaced())
                SecureField(model.hasToken ? "Token guardado (escribe para cambiarlo)" : "Token Bearer", text: $model.tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await model.saveSettings() } }
                // Cada botón en su propia fila: en una List, dos botones en la misma fila se
                // reparten mal los toques y "Guardar" podía no ejecutarse.
                Button {
                    Task { await model.saveSettings() }
                } label: {
                    Label(model.hasUnsavedSettings ? "Guardar cambios" : "Guardado",
                          systemImage: model.hasUnsavedSettings ? "square.and.arrow.down" : "checkmark")
                }
                .disabled(!model.hasUnsavedSettings)
                if model.hasToken {
                    Button("Borrar token", role: .destructive) { confirmDeleteToken = true }
                        .confirmationDialog("¿Borrar el token de este iPhone?", isPresented: $confirmDeleteToken) {
                            Button("Borrar token", role: .destructive) { model.deleteToken() }
                        }
                }
            }
        } header: {
            Text("Servidor")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if model.hasUnsavedSettings {
                    Text("Hay cambios sin guardar: se sigue enviando a la URL anterior.")
                        .foregroundStyle(.orange)
                }
                Text("En uso: \(model.savedEndpoint)").font(.caption.monospaced())
                Text("Al entrar con ZydroLogin, este iPhone recibe su propio token, que se guarda en el Keychain. Puedes revocarlo desde el panel o con «Cerrar sesión».")
            }
        }
    }

    /// ZydroLogin en una ASWebAuthenticationSession: la vuelta zydrosync://auth solo llega a
    /// esta sesión, y el código de un solo uso solo vale con el PKCE de este intento.
    private func signIn(chooseAccount: Bool) async {
        guard let attempt = model.beginLogin(chooseAccount: chooseAccount) else { return }
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: attempt.url, callbackURLScheme: AppLoginClient.callbackScheme, preferredBrowserSession: .shared)
            await model.completeLogin(callback: callback, attempt: attempt)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            model.loginCancelled(nil)
        } catch {
            model.loginCancelled("No se pudo abrir el inicio de sesión: \(error.localizedDescription)")
        }
    }
}

struct SyncStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.queueSnapshot
        Section("Sincronización") {
            Button {
                Task { await model.syncNow(manual: true) }
            } label: {
                HStack {
                    Text("Sincronizar ahora")
                    if model.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isSyncing)

            if snapshot.authPaused {
                Label("Envío pausado: el servidor rechazó el token. Guarda uno nuevo.", systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            if let error = model.setupError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            LabeledContent("Servidor") {
                Text(URL(string: model.savedEndpoint).map { "\($0.host() ?? "?"):\($0.port.map(String.init) ?? "")" } ?? "—")
                    .font(.footnote.monospaced())
            }
            LabeledContent("Última sincronización") {
                if let date = snapshot.lastSyncAt {
                    Text(date, format: .relative(presentation: .named))
                } else {
                    Text("Nunca")
                }
            }
            if let stop = model.lastReport?.stoppedBecause, stop != .alreadyRunning {
                Text(stop.rawValue).font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("Enviadas / pendientes / error",
                           value: "\(snapshot.sentCount) / \(snapshot.pendingCount) / \(snapshot.failedCount)")
            if snapshot.missingCount > 0 {
                Label("\(snapshot.missingCount) enviadas ya no están en el servidor (¿borradas desde el panel?). No se reenvían solas.",
                      systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.purple)
                Button("Reenviar las \(snapshot.missingCount) que faltan") { confirmResendMissing = true }
                    .confirmationDialog("¿Volver a subir las \(snapshot.missingCount) carreras que faltan en el servidor?",
                                        isPresented: $confirmResendMissing, titleVisibility: .visible) {
                        Button("Reenviar") { Task { await model.resendAllMissing() } }
                    }
            }
            Button {
                Task { await model.checkWithServer() }
            } label: {
                LabeledContent("Comprobar con el servidor") {
                    if let date = snapshot.lastReconciledAt {
                        Text(date, format: .relative(presentation: .named)).font(.footnote)
                    } else {
                        Text("Nunca").font(.footnote)
                    }
                }
            }
            .disabled(model.isSyncing)
            if let message = model.historyMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if snapshot.failedCount > 0 {
                Button("Reintentar todas las que tienen error") { Task { await model.retryAllFailed() } }
            }
            if snapshot.sentCount > 0 {
                Button("Borrar enviadas y volver a enviar", role: .destructive) {
                    confirmForget = true
                }
                .confirmationDialog("¿Borrar las \(snapshot.sentCount) enviadas de la cola?",
                                    isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Borrar y volver a enviar", role: .destructive) {
                        Task { await model.forgetSentAndResend() }
                    }
                } message: {
                    Text("La app las olvidará y las volverá a buscar en Salud para enviarlas de nuevo, por ejemplo a un servidor nuevo. Si el servidor ya las tiene, no se duplican. No borra nada de Salud ni del servidor.")
                }
            }
        }
    }

    @State private var confirmForget = false
    @State private var confirmResendMissing = false
}

struct HistorySection: View {
    @Environment(AppModel.self) private var model
    @State private var since = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    @State private var didSetDefault = false
    @State private var confirmImport = false
    @State private var confirmCancel = false

    var body: some View {
        let progress = model.queueSnapshot.historic
        Section {
            DatePicker("Desde", selection: $since, in: ...Date.now, displayedComponents: .date)
            Button("Importar carreras desde esta fecha") { confirmImport = true }
                .disabled(model.isSyncing)
                .confirmationDialog("¿Importar las carreras del Apple Watch desde el \(since.formatted(date: .long, time: .omitted))?",
                                    isPresented: $confirmImport, titleVisibility: .visible) {
                    Button("Importar") { Task { await model.importHistory(since: since) } }
                } message: {
                    Text("Se añaden a la cola y se envían por detrás de las recientes. Antes se compara con el servidor: las que ya tiene no se vuelven a subir.")
                }
            if progress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    Text("\(progress.done) de \(progress.total) en el servidor" + (progress.pending > 0 ? " · \(progress.pending) pendientes" : ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if progress.pending > 0 {
                    Button("Cancelar importación", role: .destructive) { confirmCancel = true }
                        .confirmationDialog("¿Quitar de la cola las \(progress.pending) carreras del histórico que aún no se han enviado?",
                                            isPresented: $confirmCancel, titleVisibility: .visible) {
                            Button("Cancelar importación", role: .destructive) { Task { await model.cancelHistoryImport() } }
                        }
                }
            }
        } header: {
            Text("Histórico")
        } footer: {
            Text("Las carreras nuevas se envían solas. Las anteriores a la instalación de la app solo se envían si las importas aquí. Si cierras la app, continúa al volver a abrirla.")
        }
        .onChange(of: model.oldestWorkoutStart, initial: true) { _, oldest in
            // La primera vez, propone la carrera más antigua de Salud (o la fecha ya importada).
            guard !didSetDefault, let date = model.queueSnapshot.historyImportSince ?? oldest else { return }
            since = Calendar.current.startOfDay(for: date)
            didSetDefault = true
        }
    }
}

struct QueueSection: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "Todas", pending = "Pendientes", missing = "Faltan", failed = "Error"

        func matches(_ item: QueueItem) -> Bool {
            switch self {
            case .all: true
            case .pending: item.status == .pending
            case .missing: item.status == .missingOnServer
            case .failed: item.status == .failed
            }
        }
    }

    var body: some View {
        let all = model.queueSnapshot.items
        let items = all.filter(filter.matches)
        Section("Cola (\(all.count))") {
            Picker("Mostrar", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if items.isEmpty {
                Text(all.isEmpty
                     ? "Vacía. Las carreras de las últimas 48 h anteriores a la instalación y todas las posteriores se añaden solas."
                     : "Ninguna.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(100)) { item in
                QueueRow(item: item)
                    .swipeActions {
                        switch item.status {
                        case .pending, .failed:
                            Button("Reintentar") { Task { await model.retry(item.id) } }
                                .tint(.blue)
                        case .sent, .missingOnServer:
                            Button("Reenviar") { Task { await model.resend(item.id) } }
                                .tint(.purple)
                        }
                    }
            }
            if items.count > 100 {
                Text("… y \(items.count - 100) más").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.workoutStart, format: .dateTime.day().month().year(.twoDigits).hour().minute())
                    .font(.headline)
                if let d = item.distanceMeters {
                    Text(String(format: "%.2f km", d / 1000)).font(.subheadline)
                }
                Spacer()
                StatusBadge(status: item.status)
            }
            // Los tiempos relativos ("dentro de 20 s") se recalculan cada 5 s.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if let detail = detail(now: context.date) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(now: Date) -> String? {
        var parts: [String] = []
        switch item.status {
        case .sent:
            if let sentAt = item.sentAt {
                parts.append("enviada \(sentAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
            } else if item.serverConfirmedAt != nil {
                parts.append("ya estaba en el servidor")
            }
            if let bytes = item.payloadBytes { parts.append("\(bytes / 1024) KB") }
            if let status = item.lastHTTPStatus { parts.append("HTTP \(status)") }
        case .pending:
            if let error = item.lastError { parts.append(error) }
            if item.attempts > 0 { parts.append("intento \(item.attempts)") }
            if item.nextAttemptAt > now {
                let seconds = Int(item.nextAttemptAt.timeIntervalSince(now).rounded(.up))
                parts.append(seconds < 120 ? "siguiente en \(seconds) s"
                    : "siguiente \(item.nextAttemptAt.formatted(.relative(presentation: .named)))")
            } else {
                parts.append("en cola")
            }
        case .failed:
            parts.append(item.lastError ?? "Error")
        case .missingOnServer:
            parts.append("no está en el servidor · desliza para reenviar")
        }
        if item.priority == .historic { parts.append("histórico") }
        if item.forceUpload == true, item.status == .pending { parts.append("reenvío") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct StatusBadge: View {
    let status: QueueItem.Status

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .sent: "Enviada"
        case .pending: "Pendiente"
        case .failed: "Error"
        case .missingOnServer: "Falta en servidor"
        }
    }

    private var color: Color {
        switch status {
        case .sent: .green
        case .pending: .orange
        case .failed: .red
        case .missingOnServer: .purple
        }
    }
}
