import Foundation

/// RawWorkout → WorkoutPayload. Función pura: sin HealthKit, sin reloj, sin I/O.
///
/// Redondeo: se redondea a una precisión útil en decimal (lat/lon 1e-7 ≈ 1 cm, offsets 1 ms…).
/// Además de quitar ruido, acorta el JSON: `round(x·10ⁿ)/10ⁿ` es una división IEEE
/// correctamente redondeada de dos enteros exactos, así que da el double más cercano a ese
/// decimal y JSONEncoder (que imprime la representación más corta) lo escribe tal cual,
/// sin colas tipo 39.469907500000004.
public enum WorkoutMapper {
    public enum Precision {
        static let time = 3
        static let coordinate = 7
        static let meters = 1
        static let speed = 2
        static let course = 1
        static let value = 3
        static let summary = 2
    }

    public static func payload(from raw: RawWorkout) -> WorkoutPayload {
        let h = raw.header
        let origin = h.startDate
        let steps = raw.series[.steps] ?? []

        let weather: WorkoutPayload.Weather? =
            (h.temperatureCelsius == nil && h.humidityPercent == nil) ? nil :
            .init(temperatureC: h.temperatureCelsius.map { round($0, 1) },
                  humidityPct: h.humidityPercent.map { round($0, 1) })

        return WorkoutPayload(
            schemaVersion: WorkoutPayload.currentSchemaVersion,
            workoutId: h.id.uuidString,
            sport: "running",
            indoor: h.isIndoor,
            startDate: iso8601(h.startDate),
            endDate: iso8601(h.endDate),
            timeZone: h.timeZone,
            durationSec: round(h.activeDuration, Precision.time),
            elapsedSec: round(h.elapsed, Precision.time),
            distanceM: h.distanceMeters.map { round($0, Precision.summary) },
            activeEnergyKcal: h.activeEnergyKcal.map { round($0, Precision.summary) },
            elevationAscendedM: h.elevationAscendedMeters.map { round($0, Precision.summary) },
            stepCount: steps.isEmpty ? nil : Int(steps.reduce(0) { $0 + $1.value }.rounded()),
            weather: weather,
            source: h.source,
            device: h.device,
            events: raw.events.map { event in
                .init(type: event.kind,
                      t: offset(event.interval.start, from: origin),
                      d: round(event.interval.duration, Precision.time))
            },
            route: h.isIndoor ? nil : route(raw.routes, origin: origin),
            series: series(raw.series, origin: origin)
        )
    }

    // MARK: Ruta

    static func route(_ segments: [[RawLocation]], origin: Date) -> WorkoutPayload.Route? {
        var route = WorkoutPayload.Route()
        var starts: [Int] = []
        let total = segments.reduce(0) { $0 + $1.count }
        for keyPath in [\WorkoutPayload.Route.t, \.lat, \.lon, \.alt, \.hAcc, \.vAcc, \.speed, \.course] {
            route[keyPath: keyPath].reserveCapacity(total)
        }

        for segment in segments where !segment.isEmpty {
            starts.append(route.count)
            for p in segment {
                // Un punto sin coordenadas válidas no aporta nada y rompería JSONEncoder (NaN).
                guard p.latitude.isFinite, p.longitude.isFinite else { continue }
                route.t.append(offset(p.timestamp, from: origin))
                route.lat.append(round(p.latitude, Precision.coordinate))
                route.lon.append(round(p.longitude, Precision.coordinate))
                route.alt.append(finiteOr(round(p.altitude, Precision.meters), -1))
                route.hAcc.append(finiteOr(round(p.horizontalAccuracy, Precision.meters), -1))
                route.vAcc.append(finiteOr(round(p.verticalAccuracy, Precision.meters), -1))
                route.speed.append(finiteOr(round(p.speed, Precision.speed), -1))
                route.course.append(finiteOr(round(p.course, Precision.course), -1))
            }
        }
        guard route.count > 0 else { return nil }
        route.segmentStarts = starts.count > 1 ? starts : nil
        return route
    }

    // MARK: Series

    static func series(_ raw: [SeriesKind: [RawSample]], origin: Date) -> WorkoutPayload.Series {
        var out = WorkoutPayload.Series()
        out.heartRate = timeSeries(raw[.heartRate], origin: origin)
        out.speed = timeSeries(raw[.speed], origin: origin)
        out.steps = timeSeries(raw[.steps], origin: origin)
        out.cadence = timeSeries(cadence(fromSteps: raw[.steps] ?? []), origin: origin)
        out.distance = timeSeries(raw[.distance], origin: origin)
        out.activeEnergy = timeSeries(raw[.activeEnergy], origin: origin)
        out.power = timeSeries(raw[.power], origin: origin)
        out.strideLength = timeSeries(raw[.strideLength], origin: origin)
        out.verticalOscillation = timeSeries(raw[.verticalOscillation], origin: origin)
        out.groundContactTime = timeSeries(raw[.groundContactTime], origin: origin)
        return out
    }

    /// Ventana mínima de agregación de la cadencia.
    static let cadenceWindow: TimeInterval = 10
    /// Un bloque final (o cortado por un hueco) más corto que esto se descarta.
    static let cadenceMinWindow: TimeInterval = 5
    /// Hueco entre muestras de pasos a partir del cual se cierra la ventana (pausa, parada).
    static let cadenceMaxGap: TimeInterval = 1

    /// HealthKit no tiene tipo "cadencia de carrera": el Watch escribe stepCount en bloques de
    /// ~2,5 s con un número ENTERO de pasos (7 u 8). Calcular la cadencia bloque a bloque
    /// produce un artefacto de cuantización (164,3 / 187,8 ppm alternando cuando la real es
    /// ~173). Por eso se agregan bloques contiguos hasta cubrir ≥ 10 s:
    /// cadencia = Σ pasos / Σ duración × 60. Resolución de 10 s, suficiente para una gráfica;
    /// los pasos brutos se envían también por si el servidor quiere otra ventana.
    static func cadence(fromSteps steps: [RawSample]) -> [RawSample] {
        var out: [RawSample] = []
        var bucketStart: Date?
        var bucketEnd: Date?
        var stepSum = 0.0
        var covered: TimeInterval = 0

        func flush() {
            if let s = bucketStart, let e = bucketEnd, covered >= cadenceMinWindow {
                out.append(RawSample(start: s, end: e, value: stepSum / covered * 60))
            }
            bucketStart = nil
            bucketEnd = nil
            stepSum = 0
            covered = 0
        }

        for sample in steps.sorted(by: { $0.start < $1.start }) {
            let duration = sample.end.timeIntervalSince(sample.start)
            guard duration > 0, sample.value.isFinite else { continue }
            if let end = bucketEnd, sample.start.timeIntervalSince(end) > cadenceMaxGap {
                flush()
            }
            if bucketStart == nil { bucketStart = sample.start }
            bucketEnd = max(bucketEnd ?? sample.end, sample.end)
            stepSum += sample.value
            covered += duration
            if covered >= cadenceWindow { flush() }
        }
        flush()
        return out
    }

    static func timeSeries(_ samples: [RawSample]?, origin: Date) -> WorkoutPayload.TimeSeries? {
        let samples = (samples ?? []).filter { $0.value.isFinite }
        guard !samples.isEmpty else { return nil }
        let t = samples.map { offset($0.start, from: origin) }
        let d = samples.map { round($0.end.timeIntervalSince($0.start), Precision.time) }
        let v = samples.map { round($0.value, Precision.value) }
        return .init(t: t, d: d.allSatisfy { $0 == 0 } ? nil : d, v: v)
    }

    // MARK: Utilidades

    static func offset(_ date: Date, from origin: Date) -> Double {
        round(date.timeIntervalSince(origin), Precision.time)
    }

    static func round(_ x: Double, _ decimals: Int) -> Double {
        guard x.isFinite else { return x }
        let m = pow(10, Double(decimals))
        return (x * m).rounded() / m
    }

    static func finiteOr(_ x: Double, _ fallback: Double) -> Double {
        x.isFinite ? x : fallback
    }

    static func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
