import Domain
import Foundation
import HealthReading
import SyncCore

/// Adaptador HealthReading → SyncCore. Vive en la app para que ninguno de los dos módulos
/// dependa del otro: SyncCore no sabe que existe HealthKit.
struct HealthKitWorkoutSource: WorkoutSource {
    let reader: HealthKitReader

    func newWorkouts(after anchor: Data?) async throws -> (workouts: [WorkoutHeader], anchor: Data) {
        do {
            let result = try await reader.fetchRunningWorkouts(after: anchor)
            return (result.workouts.filter(\.verdict.isAccepted).map(\.header), result.newAnchor)
        } catch HealthReadingError.invalidAnchor {
            // Ancla ilegible (no debería pasar): se redescubre desde cero. La cola deduplica
            // por UUID y el corte por fecha de instalación evita reenviar el histórico.
            let result = try await reader.fetchRunningWorkouts(after: nil)
            return (result.workouts.filter(\.verdict.isAccepted).map(\.header), result.newAnchor)
        } catch {
            throw Self.map(error)
        }
    }

    func rawWorkout(id: UUID) async throws -> RawWorkout {
        do {
            return try await reader.readWorkout(id: id)
        } catch {
            throw Self.map(error)
        }
    }

    func workouts(from start: Date, to end: Date) async throws -> [WorkoutHeader] {
        do {
            return try await reader.runningWorkouts(from: start, to: end).filter(\.verdict.isAccepted).map(\.header)
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: any Error) -> WorkoutSourceError {
        switch error as? HealthReadingError {
        case .protectedDataUnavailable: .locked
        case .workoutNotFound: .notFound
        default: .other(AppModel.describe(error))
        }
    }
}
