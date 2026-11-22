import Domain
import HealthReading
import SwiftUI

/// Muestra lo que HealthReading extrae de una carrera. Es la herramienta de la fase (a)
/// para comprobar en el dispositivo que llegan todas las series y la ruta.
struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    let workout: DiscoveredWorkout

    @State private var raw: RawWorkout?
    @State private var error: String?
    @State private var elapsed: Duration?
    @State private var export: PayloadExport?

    var body: some View {
        List {
            Section("Origen") {
                row("Fuente", workout.header.source.name)
                row("Bundle", workout.header.source.bundleId)
                row("productType", workout.header.source.productType ?? "nil")
                row("SO", workout.header.source.osVersion ?? "nil")
                row("Dispositivo", [workout.header.device?.name, workout.header.device?.model, workout.header.device?.hardwareVersion]
                    .compactMap { $0 }.joined(separator: " · "))
                row("Veredicto", "\(workout.verdict)")
            }
            Section("Cabecera") {
                row("UUID", workout.id.uuidString)
                row("Activo / total", "\(Int(workout.header.activeDuration)) s / \(Int(workout.header.elapsed)) s")
                row("Distancia", workout.header.distanceMeters.map { String(format: "%.1f m", $0) } ?? "nil")
                row("Energía", workout.header.activeEnergyKcal.map { String(format: "%.0f kcal", $0) } ?? "nil")
                row("Desnivel +", workout.header.elevationAscendedMeters.map { String(format: "%.0f m", $0) } ?? "nil")
                row("Zona horaria", workout.header.timeZone ?? "nil")
                row("Clima", [workout.header.temperatureCelsius.map { String(format: "%.1f ºC", $0) },
                              workout.header.humidityPercent.map { String(format: "%.0f %%", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                row("Interior", workout.header.isIndoor ? "sí" : "no")
            }
            if let raw {
                Section("Ruta") {
                    row("Segmentos", "\(raw.routes.count)")
                    row("Puntos", "\(raw.routePointCount)")
                    if let first = raw.routes.first?.first, let last = raw.routes.last?.last {
                        row("Primer fix", "+\(Int(first.timestamp.timeIntervalSince(workout.header.startDate))) s")
                        row("Último fix", "+\(Int(last.timestamp.timeIntervalSince(workout.header.startDate))) s")
                    }
                }
                Section("Series") {
                    ForEach(SeriesKind.allCases, id: \.self) { kind in
                        let samples = raw.series[kind] ?? []
                        VStack(alignment: .leading) {
                            HStack {
                                Text(kind.rawValue).font(.body.monospaced())
                                Spacer()
                                Text("\(samples.count)")
                            }
                            Text(seriesDetail(kind, samples, raw.lookup[kind]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Eventos") {
                    let counts = Dictionary(grouping: raw.events, by: \.kind).mapValues(\.count)
                    if counts.isEmpty { Text("Ninguno") }
                    ForEach(counts.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { entry in
                        row(entry.key.rawValue, "\(entry.value)")
                    }
                }
                if let elapsed {
                    Section { row("Tiempo de lectura", elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))) }
                }
                Section("Payload JSON") {
                    if let export {
                        row("JSON", ByteCountFormatter.string(fromByteCount: Int64(export.jsonBytes), countStyle: .file))
                        row("gzip", ByteCountFormatter.string(fromByteCount: Int64(export.gzipBytes), countStyle: .file))
                        row("Mapeo + JSON + gzip", export.encodeTime.formatted(.units(allowed: [.seconds, .milliseconds])))
                        ShareLink("Compartir JSON", item: export.url)
                    } else {
                        Button("Generar JSON") {
                            Task {
                                do { export = try await AppModel.export(raw) }
                                catch { self.error = AppModel.describe(error) }
                            }
                        }
                    }
                }
            } else if let error {
                Section { Text(error).foregroundStyle(.red) }
            } else {
                Section { ProgressView("Leyendo de Salud…") }
            }
        }
        .navigationTitle("Detalle")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                raw = try await model.read(workout.id)
                elapsed = clock.now - start
            } catch {
                self.error = AppModel.describe(error)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value.isEmpty ? "—" : value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func seriesDetail(_ kind: SeriesKind, _ samples: [RawSample], _ lookup: SampleLookup?) -> String {
        guard let first = samples.first, let last = samples.last else {
            return "sin datos · \(lookup?.summary ?? "?")"
        }
        let values = samples.map(\.value)
        let summary: String
        if kind.isCumulative {
            summary = String(format: "Σ %.1f %@", values.reduce(0, +), kind.unitDescription)
        } else {
            let avg = values.reduce(0, +) / Double(values.count)
            summary = String(format: "min %.1f · media %.1f · máx %.1f %@",
                             values.min() ?? 0, avg, values.max() ?? 0, kind.unitDescription)
        }
        let span = Int(last.end.timeIntervalSince(first.start))
        return "\(summary) · \(span) s · \(lookup?.summary ?? "?")"
    }
}
