// swift-tools-version: 6.0
import PackageDescription

// macOS se declara solo para poder ejecutar `swift test` sin simulador:
// Domain, SyncCore y Transport no importan HealthKit, y HealthReading compila contra el
// HealthKit de macOS (que existe desde macOS 13, aunque allí isHealthDataAvailable() sea false).
//
// Dependencias (ninguna capa de abajo conoce a las de arriba):
//   Domain ← HealthReading
//   Domain ← SyncCore ← Transport
// La app une HealthReading con SyncCore mediante un adaptador (WorkoutSource).
let package = Package(
    name: "ZydroCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ZydroCore", targets: ["Domain", "HealthReading", "SyncCore", "Transport"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "HealthReading", dependencies: ["Domain"]),
        .target(name: "SyncCore", dependencies: ["Domain"]),
        .target(name: "Transport", dependencies: ["Domain", "SyncCore"]),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore", "Domain"]),
        .testTarget(name: "TransportTests", dependencies: ["Transport", "SyncCore"]),
    ]
)
