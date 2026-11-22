import Foundation

/// Cuerpo de `POST /v1/workouts` (contract/openapi.yaml, `WorkoutUpload`).
///
/// Los opcionales a nil se OMITEN del JSON (encodeIfPresent sintetizado), lo que el
/// esquema permite: ningún campo opcional es `required`.
public struct WorkoutPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workoutId: String
    public var sport: String
    public var indoor: Bool
    /// ISO 8601 UTC con milisegundos. Origen de todos los offsets `t`.
    public var startDate: String
    public var endDate: String
    public var timeZone: String?
    public var durationSec: Double
    public var elapsedSec: Double
    public var distanceM: Double?
    public var activeEnergyKcal: Double?
    public var elevationAscendedM: Double?
    public var stepCount: Int?
    public var weather: Weather?
    public var source: SourceInfo
    public var device: DeviceInfo?
    public var events: [Event]
    public var route: Route?
    public var series: Series

    public struct Weather: Codable, Sendable, Equatable {
        public var temperatureC: Double?
        public var humidityPct: Double?
    }

    public struct Event: Codable, Sendable, Equatable {
        public var type: WorkoutEventKind
        public var t: Double
        public var d: Double
    }

    /// Arrays paralelos (columnar). `segmentStarts` solo si hay más de un segmento.
    public struct Route: Codable, Sendable, Equatable {
        public var t: [Double] = []
        public var lat: [Double] = []
        public var lon: [Double] = []
        public var alt: [Double] = []
        public var hAcc: [Double] = []
        public var vAcc: [Double] = []
        public var speed: [Double] = []
        public var course: [Double] = []
        public var segmentStarts: [Int]?

        public var count: Int { t.count }
    }

    public struct TimeSeries: Codable, Sendable, Equatable {
        public var t: [Double]
        /// Omitido cuando todas las muestras son instantáneas (FC, potencia…).
        public var d: [Double]?
        public var v: [Double]
    }

    public struct Series: Codable, Sendable, Equatable {
        public var heartRate: TimeSeries?
        public var speed: TimeSeries?
        public var cadence: TimeSeries?
        public var steps: TimeSeries?
        public var distance: TimeSeries?
        public var activeEnergy: TimeSeries?
        public var power: TimeSeries?
        public var strideLength: TimeSeries?
        public var verticalOscillation: TimeSeries?
        public var groundContactTime: TimeSeries?

        public init() {}
    }
}
