import Domain
import HealthKit

enum HealthDataTypes {
    static func quantityType(_ kind: SeriesKind) -> HKQuantityType {
        switch kind {
        case .heartRate: HKQuantityType(.heartRate)
        case .speed: HKQuantityType(.runningSpeed)
        case .steps: HKQuantityType(.stepCount)
        case .distance: HKQuantityType(.distanceWalkingRunning)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        case .power: HKQuantityType(.runningPower)
        case .strideLength: HKQuantityType(.runningStrideLength)
        case .verticalOscillation: HKQuantityType(.runningVerticalOscillation)
        case .groundContactTime: HKQuantityType(.runningGroundContactTime)
        }
    }

    /// Debe coincidir con `SeriesKind.unitDescription`.
    static func unit(_ kind: SeriesKind) -> HKUnit {
        switch kind {
        case .heartRate: .count().unitDivided(by: .minute())
        case .speed: .meter().unitDivided(by: .second())
        case .steps: .count()
        case .distance: .meter()
        case .activeEnergy: .kilocalorie()
        case .power: .watt()
        case .strideLength: .meter()
        case .verticalOscillation: .meterUnit(with: .centi)
        case .groundContactTime: .secondUnit(with: .milli)
        }
    }

    /// Solo lectura. No pedimos escritura, así que no hace falta NSHealthUpdateUsageDescription.
    /// Las rutas no necesitan permiso de ubicación: son datos de Salud.
    static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for kind in SeriesKind.allCases {
            types.insert(quantityType(kind))
        }
        return types
    }

    /// Función y no `static let`: NSPredicate no es Sendable.
    static func runningPredicate() -> NSPredicate { HKQuery.predicateForWorkouts(with: .running) }
}
