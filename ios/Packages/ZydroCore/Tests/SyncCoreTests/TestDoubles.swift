import Domain
import Foundation
@testable import SyncCore

final class InMemoryQueueStore: QueueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: QueueManifest?
    private(set) var saveCount = 0

    init(_ initial: QueueManifest? = nil) { stored = initial }

    func load() throws -> QueueManifest? { lock.withLock { stored } }

    func save(_ manifest: QueueManifest) throws {
        lock.withLock {
            stored = manifest
            saveCount += 1
        }
    }

    var current: QueueManifest? { lock.withLock { stored } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

actor FakeSource: WorkoutSource {
    var workouts: [WorkoutHeader] = []
    var routePoints: [UUID: Int] = [:]
    var locked = false
    var deleted: Set<UUID> = []
    private var anchorCounter = 0

    func add(_ header: WorkoutHeader, routePoints: Int = 10) {
        workouts.append(header)
        self.routePoints[header.id] = routePoints
    }

    func setLocked(_ value: Bool) { locked = value }
    func delete(_ id: UUID) { deleted.insert(id) }

    /// Imita la consulta anclada: el ancla es "cuántas carreras has visto".
    func newWorkouts(after anchor: Data?) async throws -> (workouts: [WorkoutHeader], anchor: Data) {
        if locked { throw WorkoutSourceError.locked }
        let seen = anchor.map { Int(String(decoding: $0, as: UTF8.self)) ?? 0 } ?? 0
        let new = Array(workouts.dropFirst(seen))
        anchorCounter = workouts.count
        return (new, Data(String(anchorCounter).utf8))
    }

    func rawWorkout(id: UUID) async throws -> RawWorkout {
        if locked { throw WorkoutSourceError.locked }
        guard !deleted.contains(id), let header = workouts.first(where: { $0.id == id }) else {
            throw WorkoutSourceError.notFound
        }
        let points = (0 ..< (routePoints[id] ?? 0)).map { i in
            RawLocation(timestamp: header.startDate.addingTimeInterval(Double(i)), latitude: 41.45, longitude: 2.2,
                        altitude: 10, horizontalAccuracy: 3, verticalAccuracy: 2, speed: 3, course: 90)
        }
        return RawWorkout(header: header, events: [], routes: points.isEmpty ? [] : [points],
                          series: [.heartRate: [RawSample(start: header.startDate, end: header.startDate, value: 150)]],
                          lookup: [:])
    }
}

actor FakeUploader: WorkoutUploader {
    var configured = true
    var script: [UploadOutcome] = []
    private(set) var uploaded: [UUID] = []
    private(set) var bodies: [Data] = []

    func setConfigured(_ value: Bool) { configured = value }
    func enqueueOutcomes(_ outcomes: [UploadOutcome]) { script.append(contentsOf: outcomes) }

    func isConfigured() async -> Bool { configured }

    func upload(workoutID: UUID, gzippedJSON: Data) async -> UploadOutcome {
        uploaded.append(workoutID)
        bodies.append(gzippedJSON)
        return script.isEmpty ? .success(status: 201) : script.removeFirst()
    }
}

enum F {
    static let t0 = Date(timeIntervalSince1970: 1_795_000_000)

    static func header(_ n: Int, start: Date, duration: TimeInterval = 1800, indoor: Bool = false) -> WorkoutHeader {
        WorkoutHeader(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!,
            startDate: start, endDate: start.addingTimeInterval(duration), activeDuration: duration,
            isIndoor: indoor, distanceMeters: 5000,
            source: SourceInfo(bundleId: "com.apple.health.X", name: "Watch", productType: "Watch7,12")
        )
    }
}
