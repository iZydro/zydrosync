import Foundation

public protocol QueueStore: Sendable {
    func load() throws -> QueueManifest?
    func save(_ manifest: QueueManifest) throws
}

/// JSON en Application Support, escrito de forma atómica (fichero temporal + rename).
///
/// Por qué JSON y no SwiftData/SQLite: son unos pocos miles de registros pequeños como
/// mucho (~250 B cada uno), siempre se leen enteros, y el actor que los posee ya serializa
/// el acceso. `ModelContext` no es Sendable y obligaría a usar @ModelActor para nada.
///
/// Protección `completeUntilFirstUserAuthentication`: el fichero se puede leer con el
/// iPhone bloqueado (después del primer desbloqueo tras arrancar), que es cuando corre la
/// sincronización en background. Solo contiene UUIDs, fechas y estados, no datos de salud.
public struct FileQueueStore: QueueStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
            .appendingPathComponent("ZydroTrackSync", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    public func load() throws -> QueueManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(QueueManifest.self, from: data)
        } catch {
            // Fichero corrupto o de una versión incompatible: se aparta (no se borra, por si
            // hay que diagnosticar) y se empieza de cero. Coste: se vuelve a descubrir desde
            // la fecha de instalación y el servidor deduplica por UUID.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    public func save(_ manifest: QueueManifest) throws {
        let data = try Self.encoder.encode(manifest)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
