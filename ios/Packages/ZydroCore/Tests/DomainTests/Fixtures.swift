import Domain
import Foundation

enum Fixtures {
    /// 2026-11-20T07:00:00Z
    static let start = Date(timeIntervalSince1970: 1_795_158_000)

    static func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    static let source = SourceInfo(bundleId: "com.apple.health.ABC", name: "Apple Watch",
                                   version: "11.1", productType: "Watch7,3", osVersion: "11.1.0")

    static func header(indoor: Bool = false, duration: Double = 600) -> WorkoutHeader {
        WorkoutHeader(
            id: UUID(uuidString: "8C1E0B3A-1111-4222-8333-944455556666")!,
            startDate: start,
            endDate: at(duration + 30),
            activeDuration: duration,
            isIndoor: indoor,
            timeZone: "Europe/Madrid",
            distanceMeters: 2012.345678,
            activeEnergyKcal: 150.55555,
            elevationAscendedMeters: 12.3456,
            temperatureCelsius: 11.04,
            humidityPercent: 81.25,
            source: source,
            device: DeviceInfo(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: "Watch7,3")
        )
    }

    static func location(_ t: Double, lat: Double = 39.4699075123, lon: Double = -0.3762881999) -> RawLocation {
        RawLocation(timestamp: at(t), latitude: lat, longitude: lon, altitude: 15.678,
                    horizontalAccuracy: 3.21, verticalAccuracy: 2.04, speed: 3.456, course: 271.37)
    }

    static func sample(_ t: Double, _ d: Double, _ v: Double) -> RawSample {
        RawSample(start: at(t), end: at(t + d), value: v)
    }

    static func workout(indoor: Bool = false,
                        routes: [[RawLocation]] = [[location(0.5), location(1.5)]],
                        series: [SeriesKind: [RawSample]] = [:],
                        events: [RawEvent] = []) -> RawWorkout {
        RawWorkout(header: header(indoor: indoor), events: events, routes: routes,
                   series: series, lookup: [:])
    }
}
