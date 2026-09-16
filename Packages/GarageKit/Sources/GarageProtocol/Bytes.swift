import Foundation

extension Data {
    /// Parses a hex string ("a1b2…"). Returns nil for odd length or non-hex characters.
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.nibble(chars[i]), let lo = Data.nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Space-separated hex for protocol logs: "01 a3 ff".
    public var hexDump: String { map { String(format: "%02x", $0) }.joined(separator: " ") }

    public static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Compares MACs without leaking how many leading bytes matched.
    public func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(self, other) { diff |= a ^ b }
        return diff == 0
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48   // 0-9
        case 65...70: return c - 55   // A-F
        case 97...102: return c - 87  // a-f
        default: return nil
        }
    }
}

public enum WireError: Error, Equatable {
    case truncated
    case trailingBytes
    case invalidValue(String)
}

/// Cursor over a frame. Copies into [UInt8] so Data slice indices never leak into parsing.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw WireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func data(_ count: Int) throws -> Data {
        guard remaining >= count else { throw WireError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }

    func expectEnd() throws {
        guard remaining == 0 else { throw WireError.trailingBytes }
    }
}
