import Domain
import Testing

@Suite("WorkoutSourceFilter")
struct WorkoutSourceFilterTests {
    let filter = WorkoutSourceFilter.appleWatchWorkoutApp
    let watchDevice = DeviceInfo(name: "Apple Watch", manufacturer: "Apple Inc.", model: "Watch", hardwareVersion: "Watch7,3")

    @Test("App Entreno del Apple Watch: aceptada")
    func appleWorkoutApp() {
        let source = SourceInfo(bundleId: "com.apple.health.6A2B1C3D-0000-4E1F-9A9A-123456789ABC",
                                name: "Apple Watch de Isidro", productType: "Watch7,3")
        #expect(filter.verdict(source: source, device: watchDevice) == .accepted)
    }

    @Test("Garmin Connect escribe desde el iPhone: descartada")
    func garminConnect() {
        let source = SourceInfo(bundleId: "com.garmin.connect.mobile", name: "Connect", productType: "iPhone16,1")
        let garmin = DeviceInfo(name: "Forerunner 965", manufacturer: "Garmin", model: "Forerunner 965")
        #expect(filter.verdict(source: source, device: garmin) == .notAppleWatch)
    }

    @Test("Strava grabando en el iPhone: descartada")
    func stravaOnPhone() {
        let source = SourceInfo(bundleId: "com.strava.stravaride", name: "Strava", productType: "iPhone16,1")
        #expect(filter.verdict(source: source, device: nil) == .notAppleWatch)
    }

    @Test("App de terceros en el Watch: descartada por bundle")
    func thirdPartyWatchApp() {
        let source = SourceInfo(bundleId: "com.example.workoutdoors.watchkitapp", name: "WorkOutDoors", productType: "Watch6,18")
        #expect(filter.verdict(source: source, device: watchDevice) == .thirdPartyApp(bundleId: "com.example.workoutdoors.watchkitapp"))
    }

    @Test("Entreno grabado en el propio iPhone (Apple): descartado")
    func appleOnPhone() {
        let source = SourceInfo(bundleId: "com.apple.health.ABCD", name: "iPhone", productType: "iPhone16,1")
        #expect(filter.verdict(source: source, device: nil) == .notAppleWatch)
    }

    @Test("Sin productType se usa el modelo del dispositivo", arguments: [
        (DeviceInfo(model: "Watch"), true),
        (DeviceInfo(model: "iPhone"), false),
        (nil, false),
    ] as [(DeviceInfo?, Bool)])
    func missingProductType(device: DeviceInfo?, accepted: Bool) {
        let source = SourceInfo(bundleId: "com.apple.health.X", name: "Apple Watch", productType: nil)
        #expect(filter.verdict(source: source, device: device).isAccepted == accepted)
    }

    @Test("El prefijo de bundle exige un punto: com.apple.healthfoo no cuela")
    func bundlePrefixBoundary() {
        let source = SourceInfo(bundleId: "com.apple.healthfoo.app", name: "X", productType: "Watch7,1")
        #expect(filter.verdict(source: source, device: watchDevice) == .thirdPartyApp(bundleId: "com.apple.healthfoo.app"))
    }

    @Test("Comparación de bundle sin distinguir mayúsculas")
    func caseInsensitive() {
        let source = SourceInfo(bundleId: "com.apple.Health.ABC", name: "Apple Watch", productType: "Watch7,1")
        #expect(filter.verdict(source: source, device: watchDevice) == .accepted)
    }
}
