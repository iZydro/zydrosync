import CoreLocation
import Domain
import Foundation
import HealthKit

public struct DiscoveredWorkout: Sendable, Hashable, Identifiable {
    public var header: WorkoutHeader
    public var verdict: WorkoutSourceFilter.Verdict
    public var id: UUID { header.id }
}

public struct AnchoredFetch: Sendable {
    /// Todas las carreras nuevas, con su veredicto. El filtrado lo decide quien llama,
    /// para que la UI pueda mostrar también las descartadas (útil para verificar el filtro).
    public var workouts: [DiscoveredWorkout]
    public var deletedIDs: [UUID]
    /// Ancla opaca serializada con NSKeyedArchiver. Se persiste DESPUÉS de encolar (fase c).
    public var newAnchor: Data
}

public enum AuthorizationRequestState: Sendable, Hashable {
    /// Nunca se ha mostrado la hoja de permisos.
    case shouldRequest
    /// Ya se mostró. OJO: HealthKit no deja saber si el usuario denegó la LECTURA
    /// (por privacidad, una lectura denegada simplemente devuelve cero resultados).
    case alreadyRequested
    case unknown
}

public enum HealthReadingError: Error, Sendable, Hashable {
    case healthDataUnavailable
    /// Dispositivo bloqueado: la base de datos de Salud está cifrada. No es un fallo,
    /// hay que reintentar tras `protectedDataDidBecomeAvailable`.
    case protectedDataUnavailable
    case workoutNotFound(UUID)
    case invalidAnchor
    case underlying(String)
}

/// Única pieza que conoce HealthKit. Devuelve siempre tipos de Domain (Sendable, testeables).
///
/// Es un struct Sendable y no un actor: no tiene estado mutable (HKHealthStore es
/// thread-safe y Sendable), y los resultados de los descriptores de HealthKit no son
/// Sendable. Con métodos no aislados, esos resultados se crean y se convierten a tipos de
/// Domain en el mismo contexto, sin cruzar ningún dominio de aislamiento.
public struct HealthKitReader: Sendable {
    private let store: HKHealthStore
    public let filter: WorkoutSourceFilter

    public init(store: HKHealthStore = HKHealthStore(),
                filter: WorkoutSourceFilter = .appleWatchWorkoutApp) {
        self.store = store
        self.filter = filter
    }

    public static var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: Permisos

    public func requestAuthorization() async throws {
        try await Self.mapErrors {
            try await store.requestAuthorization(toShare: [], read: HealthDataTypes.readTypes)
        }
    }

    public func authorizationRequestState() async throws -> AuthorizationRequestState {
        let status = try await Self.mapErrors {
            try await store.statusForAuthorizationRequest(toShare: [], read: HealthDataTypes.readTypes)
        }
        switch status {
        case .shouldRequest: return .shouldRequest
        case .unnecessary: return .alreadyRequested
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: Descubrimiento

    /// Consulta anclada sobre TODAS las carreras (sin filtrar por origen en el predicado:
    /// ver WorkoutSourceFilter). El ancla avanza también sobre las carreras de Garmin, lo
    /// cual es correcto: no las queremos nunca.
    public func fetchRunningWorkouts(after anchorData: Data?, limit: Int? = nil) async throws -> AnchoredFetch {
        let anchor = try anchorData.map(Self.decodeAnchor)
        let descriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [.workout(HealthDataTypes.runningPredicate())],
            anchor: anchor,
            limit: limit
        )
        let result = try await Self.mapErrors { try await descriptor.result(for: store) }
        return AnchoredFetch(
            workouts: result.addedSamples.map(discovered),
            deletedIDs: result.deletedObjects.map(\.uuid),
            newAnchor: try Self.encodeAnchor(result.newAnchor)
        )
    }

    /// Para la UI y para el histórico: las últimas N carreras por fecha de fin.
    public func recentRunningWorkouts(limit: Int, since: Date? = nil) async throws -> [DiscoveredWorkout] {
        var predicate = HealthDataTypes.runningPredicate()
        if let since {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate),
            ])
        }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: limit
        )
        let workouts = try await Self.mapErrors { try await descriptor.result(for: store) }
        return workouts.map(discovered)
    }

    // MARK: Lectura completa

    public func readWorkout(id: UUID) async throws -> RawWorkout {
        let workout = try await fetchWorkout(id: id)
        let store = self.store

        return try await Self.mapErrors {
            try await withThrowingTaskGroup(of: Partial.self) { group in
                for kind in SeriesKind.allCases {
                    group.addTask {
                        let (samples, lookup) = try await Self.readSeries(kind, workout: workout, store: store)
                        return .series(kind, samples, lookup)
                    }
                }
                group.addTask {
                    .routes(try await Self.readRoutes(workout: workout, store: store))
                }

                var series: [SeriesKind: [RawSample]] = [:]
                var lookup: [SeriesKind: SampleLookup] = [:]
                var routes: [[RawLocation]] = []
                for try await part in group {
                    switch part {
                    case let .series(kind, samples, how):
                        series[kind] = samples
                        lookup[kind] = how
                    case let .routes(r):
                        routes = r
                    }
                }
                return RawWorkout(
                    header: Self.header(from: workout),
                    events: Self.events(from: workout),
                    routes: routes,
                    series: series,
                    lookup: lookup
                )
            }
        }
    }

    private enum Partial: Sendable {
        case series(SeriesKind, [RawSample], SampleLookup)
        case routes([[RawLocation]])
    }

    private func fetchWorkout(id: UUID) async throws -> HKWorkout {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObject(with: id))],
            sortDescriptors: [],
            limit: 1
        )
        guard let workout = try await Self.mapErrors({ try await descriptor.result(for: store) }).first else {
            throw HealthReadingError.workoutNotFound(id)
        }
        return workout
    }

    private func discovered(_ workout: HKWorkout) -> DiscoveredWorkout {
        let header = Self.header(from: workout)
        return DiscoveredWorkout(header: header, verdict: filter.verdict(source: header.source, device: header.device))
    }

    // MARK: Series

    /// Unión de dos vías (ver SampleLookup):
    /// - asociadas al workout (`predicateForObjects(from: workout)`);
    /// - ventana [inicio, fin] + mismo HKSource que el workout.
    /// No se usa una ventana temporal sin filtrar por origen porque, si llevas el Garmin y el
    /// Watch a la vez, mezclaría la FC de los dos.
    ///
    /// HKQuantitySeriesSampleQuery (y no HKSampleQuery): distancia, energía y a veces FC
    /// llegan como series (count > 1) y HKSampleQuery solo daría el agregado de cada una.
    static func readSeries(_ kind: SeriesKind, workout: HKWorkout,
                           store: HKHealthStore) async throws -> ([RawSample], SampleLookup) {
        let associatedPredicate = HKQuery.predicateForObjects(from: workout)
        let windowPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
            HKQuery.predicateForObjects(from: workout.sourceRevision.source),
        ])
        async let associated = collectQuantities(kind, predicate: associatedPredicate, store: store)
        async let windowed = collectQuantities(kind, predicate: windowPredicate, store: store)
        let (a, w) = try await (associated, windowed)
        let merged = SampleMerge.union(a, w)
        return (merged, SampleLookup(associated: a.count, window: w.count, merged: merged.count))
    }

    static func collectQuantities(_ kind: SeriesKind, predicate: NSPredicate,
                                              store: HKHealthStore) async throws -> [RawSample] {
        let unit = HealthDataTypes.unit(kind)
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: .quantitySample(type: HealthDataTypes.quantityType(kind), predicate: predicate),
            options: .orderByQuantitySampleStartDate
        )
        var out: [RawSample] = []
        for try await result in descriptor.results(for: store) {
            out.append(RawSample(
                start: result.dateInterval.start,
                end: result.dateInterval.end,
                value: result.quantity.doubleValue(for: unit)
            ))
        }
        // El orden de la consulta es por muestra contenedora, no por cantidad individual:
        // dos series solapadas podrían intercalarse. Ordenar es O(n log n) y nos da
        // un invariante simple para el mapper.
        out.sort { $0.start < $1.start }
        return out
    }

    // MARK: Rutas

    static func readRoutes(workout: HKWorkout, store: HKHealthStore) async throws -> [[RawLocation]] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let routes = try await descriptor.result(for: store)
        var out: [[RawLocation]] = []
        for route in routes {
            var points: [RawLocation] = []
            points.reserveCapacity(route.count)
            // HealthKit entrega la ruta por lotes; el descriptor ya lo expone como AsyncSequence.
            for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
                points.append(RawLocation(location))
            }
            out.append(points)
        }
        return out
    }

    // MARK: Conversión HK → Domain

    static func header(from workout: HKWorkout) -> WorkoutHeader {
        let revision = workout.sourceRevision
        let os = revision.operatingSystemVersion
        let source = SourceInfo(
            bundleId: revision.source.bundleIdentifier,
            name: revision.source.name,
            version: revision.version,
            productType: revision.productType,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )
        let device = workout.device.map {
            DeviceInfo(name: $0.name, manufacturer: $0.manufacturer, model: $0.model,
                       hardwareVersion: $0.hardwareVersion, softwareVersion: $0.softwareVersion)
        }
        let metadata = workout.metadata ?? [:]

        func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: unit)
        }
        func metaQuantity(_ key: String, _ unit: HKUnit) -> Double? {
            guard let q = metadata[key] as? HKQuantity, q.is(compatibleWith: unit) else { return nil }
            return q.doubleValue(for: unit)
        }

        return WorkoutHeader(
            id: workout.uuid,
            startDate: workout.startDate,
            endDate: workout.endDate,
            activeDuration: workout.duration,
            isIndoor: (metadata[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue ?? false,
            timeZone: metadata[HKMetadataKeyTimeZone] as? String,
            distanceMeters: sum(.distanceWalkingRunning, .meter()),
            activeEnergyKcal: sum(.activeEnergyBurned, .kilocalorie()),
            elevationAscendedMeters: metaQuantity(HKMetadataKeyElevationAscended, .meter()),
            temperatureCelsius: metaQuantity(HKMetadataKeyWeatherTemperature, .degreeCelsius()),
            // HKUnit.percent() debería dar una fracción 0…1, pero la app Entreno guarda 76 (no
            // 0,76) con esa unidad. Se aceptan ambas: ≤ 1 se interpreta como fracción.
            humidityPercent: metaQuantity(HKMetadataKeyWeatherHumidity, .percent()).map { $0 <= 1 ? $0 * 100 : $0 },
            source: source,
            device: device
        )
    }

    static func events(from workout: HKWorkout) -> [RawEvent] {
        (workout.workoutEvents ?? []).compactMap { event in
            let kind: WorkoutEventKind
            switch event.type {
            case .pause: kind = .pause
            case .resume: kind = .resume
            case .motionPaused: kind = .motionPaused
            case .motionResumed: kind = .motionResumed
            case .lap: kind = .lap
            case .marker: kind = .marker
            case .segment: kind = .segment
            case .pauseOrResumeRequest: kind = .pauseOrResumeRequest
            @unknown default: return nil
            }
            return RawEvent(kind: kind, interval: event.dateInterval)
        }
    }

    // MARK: Ancla y errores

    static func encodeAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func decodeAnchor(_ data: Data) throws -> HKQueryAnchor {
        guard let anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else {
            throw HealthReadingError.invalidAnchor
        }
        return anchor
    }

    static func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as HealthReadingError {
            throw error
        } catch let error as HKError {
            switch error.code {
            case .errorDatabaseInaccessible: throw HealthReadingError.protectedDataUnavailable
            case .errorHealthDataUnavailable, .errorHealthDataRestricted: throw HealthReadingError.healthDataUnavailable
            default: throw HealthReadingError.underlying(error.localizedDescription)
            }
        } catch {
            throw HealthReadingError.underlying(error.localizedDescription)
        }
    }
}

extension RawLocation {
    init(_ l: CLLocation) {
        self.init(
            timestamp: l.timestamp,
            latitude: l.coordinate.latitude,
            longitude: l.coordinate.longitude,
            altitude: l.altitude,
            horizontalAccuracy: l.horizontalAccuracy,
            verticalAccuracy: l.verticalAccuracy,
            speed: l.speed,
            course: l.course
        )
    }
}
