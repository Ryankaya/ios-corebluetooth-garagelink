import Foundation

/// 8-byte identifier used for device IDs and client (phone) IDs. Codable as a hex string.
public struct ShortID: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let length = 8
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == ShortID.length else { return nil }
        self.bytes = Data(bytes)
    }

    public init?(hex: String) {
        guard let data = Data(hex: hex) else { return nil }
        self.init(bytes: data)
    }

    public static func random() -> ShortID {
        ShortID(bytes: .random(count: length))!
    }

    public var hex: String { bytes.hex }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let id = ShortID(hex: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ShortID \(string)"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
