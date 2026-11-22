import Foundation

// Frontera entre HealthKit y el resto de la app.
//
// HealthReading copia aquí lo que lee de HealthKit, en unidades canónicas fijas,
// sin derivar nada. Todo lo que es "lógica" (offsets, cadencia, formato columnar)
// vive en Domain y se prueba sin HealthKit: HKWorkoutRoute no se puede construir
// en un test y el init de HKWorkout está deprecado.

public struct SourceInfo: Sendable, Hashable, Codable {
    public var bundleId: String
    public var name: String
    public var version: String?
    /// `HKSourceRevision.productType`, p. ej. "Watch7,3" o "iPhone16,1".
    public var productType: String?
    public var osVersion: String?

    public init(bundleId: String, name: String, version: String? = nil,
                productType: String? = nil, osVersion: String? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.version = version
        self.productType = productType
        self.osVersion = osVersion
    }
}

public struct DeviceInfo: Sendable, Hashable, Codable {
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var hardwareVersion: String?
    public var softwareVersion: String?

    public init(name: String? = nil, manufacturer: String? = nil, model: String? = nil,
                hardwareVersion: String? = nil, softwareVersion: String? = nil) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
    }
}

/// Datos de cabecera de un HKWorkout (lo que cabe en la consulta anclada, sin muestras).
public struct WorkoutHeader: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startDate: Date
    public var endDate: Date
    /// `HKWorkout.duration`: tiempo activo, excluye pausas.
    public var activeDuration: TimeInterval
    public var isIndoor: Bool
    /// Identificador IANA de `HKMetadataKeyTimeZone`.
    public var timeZone: String?
    public var distanceMeters: Double?
    public var activeEnergyKcal: Double?
    public var elevationAscendedMeters: Double?
    public var temperatureCelsius: Double?
    public var humidityPercent: Double?
    public var source: SourceInfo
    public var device: DeviceInfo?

    public init(id: UUID, startDate: Date, endDate: Date, activeDuration: TimeInterval,
                isIndoor: Bool, timeZone: String? = nil, distanceMeters: Double? = nil,
                activeEnergyKcal: Double? = nil, elevationAscendedMeters: Double? = nil,
                temperatureCelsius: Double? = nil, humidityPercent: Double? = nil,
                source: SourceInfo, device: DeviceInfo? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.activeDuration = activeDuration
        self.isIndoor = isIndoor
        self.timeZone = timeZone
        self.distanceMeters = distanceMeters
        self.activeEnergyKcal = activeEnergyKcal
        self.elevationAscendedMeters = elevationAscendedMeters
        self.temperatureCelsius = temperatureCelsius
        self.humidityPercent = humidityPercent
        self.source = source
        self.device = device
    }

    public var elapsed: TimeInterval { endDate.timeIntervalSince(startDate) }
}

public enum WorkoutEventKind: String, Sendable, Hashable, Codable {
    case pause, resume, motionPaused, motionResumed, lap, marker, segment, pauseOrResumeRequest
}

public struct RawEvent: Sendable, Hashable {
    public var kind: WorkoutEventKind
    public var interval: DateInterval

    public init(kind: WorkoutEventKind, interval: DateInterval) {
        self.kind = kind
        self.interval = interval
    }
}

/// Series que se leen de HealthKit. La unidad de cada una es fija (ver `unitDescription`).
public enum SeriesKind: String, Sendable, Hashable, CaseIterable, Codable {
    case heartRate
    case speed
    case steps
    case distance
    case activeEnergy
    case power
    case strideLength
    case verticalOscillation
    case groundContactTime

    /// Cumulativas: el valor pertenece al intervalo [start, end], no a un instante.
    public var isCumulative: Bool {
        switch self {
        case .steps, .distance, .activeEnergy: true
        default: false
        }
    }

    public var unitDescription: String {
        switch self {
        case .heartRate: "lpm"
        case .speed: "m/s"
        case .steps: "pasos"
        case .distance: "m"
        case .activeEnergy: "kcal"
        case .power: "W"
        case .strideLength: "m"
        case .verticalOscillation: "cm"
        case .groundContactTime: "ms"
        }
    }
}

public struct RawSample: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

public struct RawLocation: Sendable, Hashable {
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    /// m/s; negativo si no es válida (convención de CoreLocation).
    public var speed: Double
    /// Grados; negativo si no es válido.
    public var course: Double

    public init(timestamp: Date, latitude: Double, longitude: Double, altitude: Double,
                horizontalAccuracy: Double, verticalAccuracy: Double,
                speed: Double, course: Double) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
    }
}

/// Diagnóstico de cómo se encontraron las muestras de una serie.
///
/// Se leen por dos vías y se unen: las ASOCIADAS al workout y las de la ventana
/// [inicio, fin] con el MISMO origen que el workout. En el dispositivo real (Ultra 3,
/// watchOS 27) solo una parte de la FC viene asociada, así que quedarse con la primera
/// vía si no estaba vacía perdía casi toda la serie.
public struct SampleLookup: Sendable, Hashable {
    public var associated: Int
    public var window: Int
    public var merged: Int

    public init(associated: Int, window: Int, merged: Int) {
        self.associated = associated
        self.window = window
        self.merged = merged
    }

    public var summary: String { "asoc \(associated) · vent \(window) · total \(merged)" }
}

public enum SampleMerge {
    /// Unión sin duplicados (la misma muestra sale por las dos vías), ordenada por inicio.
    public static func union(_ a: [RawSample], _ b: [RawSample]) -> [RawSample] {
        var seen = Set<RawSample>()
        seen.reserveCapacity(a.count + b.count)
        var out: [RawSample] = []
        out.reserveCapacity(max(a.count, b.count))
        for sample in a + b where seen.insert(sample).inserted {
            out.append(sample)
        }
        out.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return out
    }
}

public struct RawWorkout: Sendable {
    public var header: WorkoutHeader
    public var events: [RawEvent]
    /// Normalmente una sola ruta; puede haber varias (se conservan separadas).
    public var routes: [[RawLocation]]
    public var series: [SeriesKind: [RawSample]]
    public var lookup: [SeriesKind: SampleLookup]

    public init(header: WorkoutHeader, events: [RawEvent], routes: [[RawLocation]],
                series: [SeriesKind: [RawSample]], lookup: [SeriesKind: SampleLookup]) {
        self.header = header
        self.events = events
        self.routes = routes
        self.series = series
        self.lookup = lookup
    }

    public var routePointCount: Int { routes.reduce(0) { $0 + $1.count } }
}
