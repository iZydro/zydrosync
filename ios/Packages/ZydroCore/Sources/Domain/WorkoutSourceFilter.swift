import Foundation

/// Decide si un entrenamiento lo grabó la app Entreno del Apple Watch.
///
/// Por qué se filtra en memoria y no con `HKQuery.predicateForObjects(from: Set<HKSource>)`:
/// el origen de la app Entreno es `com.apple.health.<UUID-del-emparejamiento>`. Si cambias
/// de reloj o lo vuelves a emparejar, el origen es otro y un predicado fijo dejaría de
/// encontrar carreras sin dar ningún error.
///
/// Por qué no basta con `productType` = "Watch…": las apps de terceros de watchOS
/// (WorkOutDoors, etc.) también lo tienen. Garmin Connect se descarta ya por productType,
/// porque escribe desde el iPhone (`iPhone…`).
public struct WorkoutSourceFilter: Sendable, Hashable {
    public enum Verdict: Sendable, Hashable {
        case accepted
        case notAppleWatch
        case thirdPartyApp(bundleId: String)

        public var isAccepted: Bool { self == .accepted }
    }

    public var watchProductTypePrefix: String
    /// Se compara en minúsculas, por igualdad exacta o como prefijo seguido de ".".
    public var allowedBundleIds: [String]

    public init(watchProductTypePrefix: String, allowedBundleIds: [String]) {
        self.watchProductTypePrefix = watchProductTypePrefix
        self.allowedBundleIds = allowedBundleIds
    }

    public static let appleWatchWorkoutApp = WorkoutSourceFilter(
        watchProductTypePrefix: "Watch",
        allowedBundleIds: ["com.apple.health"]
    )

    public func verdict(source: SourceInfo, device: DeviceInfo?) -> Verdict {
        let isWatch: Bool
        if let productType = source.productType, !productType.isEmpty {
            isWatch = productType.hasPrefix(watchProductTypePrefix)
        } else {
            // productType es opcional en HKSourceRevision (datos muy antiguos o restaurados).
            isWatch = device?.model == "Watch"
        }
        guard isWatch else { return .notAppleWatch }

        let bundleId = source.bundleId.lowercased()
        let allowed = allowedBundleIds.contains { raw in
            let prefix = raw.lowercased()
            return bundleId == prefix || bundleId.hasPrefix(prefix + ".")
        }
        return allowed ? .accepted : .thirdPartyApp(bundleId: source.bundleId)
    }
}
