@testable import Domain
import Foundation
import Testing

@Suite("PayloadEncoding")
struct PayloadEncodingTests {
    /// Claves del esquema OpenAPI `WorkoutUpload`. Si cambias el payload, cambia también
    /// contract/openapi.yaml y este conjunto.
    static let schemaKeys: Set<String> = [
        "schemaVersion", "workoutId", "sport", "indoor", "startDate", "endDate", "timeZone",
        "durationSec", "elapsedSec", "distanceM", "activeEnergyKcal", "elevationAscendedM",
        "stepCount", "weather", "source", "device", "events", "route", "series",
    ]
    static let requiredKeys: Set<String> = [
        "schemaVersion", "workoutId", "sport", "indoor", "startDate", "endDate",
        "durationSec", "elapsedSec", "source", "series",
    ]
    static let seriesKeys: Set<String> = [
        "heartRate", "speed", "cadence", "steps", "distance", "activeEnergy", "power",
        "strideLength", "verticalOscillation", "groundContactTime",
    ]

    static func fullWorkout() -> RawWorkout {
        var series: [SeriesKind: [RawSample]] = [:]
        for kind in SeriesKind.allCases {
            series[kind] = [Fixtures.sample(0, kind.isCumulative ? 5 : 0, 10)]
        }
        return Fixtures.workout(series: series, events: [
            RawEvent(kind: .lap, interval: DateInterval(start: Fixtures.at(60), duration: 0)),
        ])
    }

    @Test("Las claves del JSON coinciden con el esquema OpenAPI")
    func keysMatchSchema() throws {
        let data = try PayloadEncoding.json(WorkoutMapper.payload(from: Self.fullWorkout()))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(object.keys)
        #expect(keys.isSubset(of: Self.schemaKeys), "Sobran: \(keys.subtracting(Self.schemaKeys))")
        #expect(Self.requiredKeys.isSubset(of: keys), "Faltan: \(Self.requiredKeys.subtracting(keys))")
        let series = try #require(object["series"] as? [String: Any])
        #expect(Set(series.keys) == Self.seriesKeys)
    }

    @Test("Ida y vuelta JSON sin pérdidas")
    func roundTrip() throws {
        let payload = WorkoutMapper.payload(from: Self.fullWorkout())
        let decoded = try JSONDecoder().decode(WorkoutPayload.self, from: PayloadEncoding.json(payload))
        #expect(decoded == payload)
    }

    @Test("Salida determinista")
    func deterministic() throws {
        let payload = WorkoutMapper.payload(from: Self.fullWorkout())
        #expect(try PayloadEncoding.json(payload) == PayloadEncoding.json(payload))
    }

    @Test("CRC32 del vector de prueba estándar")
    func crc32() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test("gzip: ida y vuelta", arguments: [0, 1, 1000, 300_000])
    func gzipRoundTrip(size: Int) throws {
        var rng = SystemRandomNumberGenerator()
        // Medio aleatorio, medio repetitivo: ejercita literales y referencias de DEFLATE.
        let data = Data((0 ..< size).map { i in i % 2 == 0 ? UInt8.random(in: 0 ... 255, using: &rng) : UInt8(i % 7) })
        let gz = try Gzip.compress(data)
        #expect(gz.prefix(3) == Data([0x1F, 0x8B, 0x08]))
        #expect(try Gzip.decompress(gz) == data)
    }

    @Test("gzip: detecta corrupción")
    func gzipCorruption() throws {
        var gz = try Gzip.compress(Data("hola hola hola".utf8))
        gz[gz.count - 6] ^= 0xFF  // CRC
        #expect(throws: Gzip.Error.checksumMismatch) { try Gzip.decompress(gz) }
    }

    #if os(macOS)
    @Test("gzip: compatible con /usr/bin/gunzip")
    func gzipInterop() throws {
        let original = try PayloadEncoding.json(WorkoutMapper.payload(from: Self.fullWorkout()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json.gz")
        try Gzip.compress(original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output == original)
    }
    #endif

    @Test("Tamaño: carrera sintética de 2 h a 1 Hz")
    func sizeBudget() throws {
        let n = 7200
        let route = (0 ..< n).map { i in
            Fixtures.location(Double(i), lat: 39.46 + Double(i) * 1e-5, lon: -0.37 - Double(i) * 1.3e-5)
        }
        let hr = (0 ..< n / 5).map { Fixtures.sample(Double($0 * 5), 0, 140 + Double($0 % 30)) }
        let raw = Fixtures.workout(routes: [route], series: [.heartRate: hr, .speed: hr, .power: hr])
        let json = try PayloadEncoding.json(WorkoutMapper.payload(from: raw))
        let gz = try Gzip.compress(json)
        print("2 h sintética: JSON \(json.count / 1024) KB, gzip \(gz.count / 1024) KB")
        #expect(json.count < 1_200_000)
        #expect(gz.count < json.count / 2)
    }
}
