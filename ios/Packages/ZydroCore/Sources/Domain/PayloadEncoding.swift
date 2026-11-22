import Foundation

public enum PayloadEncoding {
    /// JSON compacto. `.sortedKeys` hace la salida determinista (útil en tests y para
    /// comparar payloads), y su coste es despreciable frente al tamaño de la ruta.
    public static func json(_ payload: WorkoutPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// Cuerpo listo para `Content-Encoding: gzip`.
    public static func gzippedJSON(_ payload: WorkoutPayload) throws -> Data {
        try Gzip.compress(json(payload))
    }
}

/// gzip (RFC 1952) sin dependencias.
///
/// `NSData.compressed(using: .zlib)` produce DEFLATE en bruto (RFC 1951), sin cabecera zlib
/// ni gzip, así que solo hay que añadir la cabecera de 10 bytes y el trailer CRC32 + ISIZE.
/// Se usa gzip y no `Content-Encoding: deflate` porque "deflate" en HTTP es ambiguo
/// (zlib vs raw) y cada servidor lo interpreta a su manera.
public enum Gzip {
    public enum Error: Swift.Error, Equatable {
        case notGzip
        case unsupportedFlags
        case truncated
        case checksumMismatch
        case sizeMismatch
    }

    public static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data(capacity: deflated.count + 18)
        // ID1 ID2 CM FLG MTIME(4) XFL OS(255 = desconocido)
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(deflated)
        appendLE(&out, CRC32.checksum(data))
        appendLE(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Solo para tests y diagnóstico: acepta gzip sin campos opcionales (lo que genera `compress`).
    public static func decompress(_ gz: Data) throws -> Data {
        let bytes = [UInt8](gz)
        guard bytes.count >= 18 else { throw Error.truncated }
        guard bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { throw Error.notGzip }
        guard bytes[3] == 0 else { throw Error.unsupportedFlags }
        let body = Data(bytes[10 ..< bytes.count - 8])
        let out = try (body as NSData).decompressed(using: .zlib) as Data
        let crc = readLE(bytes, bytes.count - 8)
        let size = readLE(bytes, bytes.count - 4)
        guard crc == CRC32.checksum(out) else { throw Error.checksumMismatch }
        guard size == UInt32(truncatingIfNeeded: out.count) else { throw Error.sizeMismatch }
        return out
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLE(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }
}

/// CRC-32 IEEE 802.3 (polinomio reflejado 0xEDB88320), el que usa gzip.
public enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { n in
        (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
