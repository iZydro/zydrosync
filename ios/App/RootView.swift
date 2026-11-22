import Domain
import HealthReading
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showRejected = true

    var body: some View {
        NavigationStack {
            List {
                SyncStatusSection()
                ServerSection()
                HistorySection()
                QueueSection()
                permissionsSection
                workoutsSection
            }
            .navigationTitle("ZydroTrack Sync")
            .refreshable {
                await model.refresh()
                await model.syncNow(manual: true)
            }
            .task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                model.protectedDataChanged(available: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                model.protectedDataChanged(available: false)
            }
        }
    }

    private var permissionsSection: some View {
        Section("Permisos") {
            LabeledContent("HealthKit", value: model.isHealthAvailable ? "Disponible" : "No disponible")
            LabeledContent("Datos protegidos", value: model.isProtectedDataAvailable ? "Accesibles" : "Bloqueado")
            LabeledContent("Solicitud", value: authLabel)
            Button("Solicitar permisos de lectura") {
                Task { await model.requestAuthorization() }
            }
            .disabled(!model.isHealthAvailable)
            if case let .failed(message) = model.phase {
                Text(message).foregroundStyle(.red).font(.footnote)
            }
            Text("iOS no permite saber si denegaste la lectura: si la lista sale vacía, revisa Ajustes › Salud › Acceso a datos › ZydroTrack Sync.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var authLabel: String {
        switch model.authState {
        case .shouldRequest: "Pendiente"
        case .alreadyRequested: "Ya solicitada"
        case .unknown, nil: "—"
        }
    }

    private var workoutsSection: some View {
        Section {
            Toggle("Mostrar descartadas", isOn: $showRejected)
            if model.phase == .loading && model.workouts.isEmpty {
                ProgressView()
            }
            ForEach(model.workouts.filter { showRejected || $0.verdict.isAccepted }) { workout in
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutRow(workout: workout)
                }
            }
        } header: {
            Text("Últimas 50 carreras en Salud")
        }
    }
}

struct WorkoutRow: View {
    let workout: DiscoveredWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(workout.header.startDate, format: .dateTime.day().month().year().hour().minute())
                    .font(.headline)
                Spacer()
                VerdictBadge(verdict: workout.verdict)
            }
            HStack(spacing: 12) {
                if let d = workout.header.distanceMeters {
                    Text(String(format: "%.2f km", d / 1000))
                }
                Text(Duration.seconds(workout.header.activeDuration), format: .time(pattern: .hourMinuteSecond))
                if workout.header.isIndoor { Text("Cinta") }
            }
            .font(.subheadline)
            Text("\(workout.header.source.name) · \(workout.header.source.productType ?? "?")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct VerdictBadge: View {
    let verdict: WorkoutSourceFilter.Verdict

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch verdict {
        case .accepted: "Watch"
        case .notAppleWatch: "No Watch"
        case .thirdPartyApp: "App terceros"
        }
    }

    private var color: Color {
        verdict.isAccepted ? .green : .orange
    }
}
