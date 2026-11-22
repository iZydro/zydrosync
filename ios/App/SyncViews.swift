import SwiftUI
import SyncCore

struct ServerSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            TextField("https://…/v1/workouts", text: $model.endpointText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            SecureField(model.hasToken ? "Token guardado (escribe para cambiarlo)" : "Token Bearer", text: $model.tokenText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Guardar") { Task { await model.saveSettings() } }
                Spacer()
                if model.hasToken {
                    Button("Borrar token", role: .destructive) { model.deleteToken() }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Servidor")
        } footer: {
            Text("El token se guarda en el Keychain del iPhone, solo en este dispositivo.")
        }
    }
}

struct SyncStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.queueSnapshot
        Section("Sincronización") {
            Button {
                Task { await model.syncNow() }
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
            if snapshot.failedCount > 0 {
                Button("Reintentar todas las que tienen error") { Task { await model.retryAllFailed() } }
            }
        }
    }
}

struct QueueSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.queueSnapshot.items
        Section("Cola (\(items.count))") {
            if items.isEmpty {
                Text("Vacía. Las carreras de las últimas 48 h anteriores a la instalación y todas las posteriores se añaden solas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items.prefix(50)) { item in
                QueueRow(item: item)
                    .swipeActions {
                        if item.status != .sent {
                            Button("Reintentar") { Task { await model.retry(item.id) } }
                                .tint(.blue)
                        }
                    }
            }
        }
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.workoutStart, format: .dateTime.day().month().hour().minute())
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
        }
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
        }
    }

    private var color: Color {
        switch status {
        case .sent: .green
        case .pending: .orange
        case .failed: .red
        }
    }
}
