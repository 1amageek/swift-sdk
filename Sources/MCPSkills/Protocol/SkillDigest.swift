import Crypto
import Foundation

/// A content digest in the form `sha256:` followed by 64 lowercase hex digits.
public struct SkillDigest: Hashable, Sendable, CustomStringConvertible {
    /// The wire spelling, for example `sha256:9f86d0…`.
    public let rawValue: String

    private static let prefix = "sha256:"

    /// Validates a wire spelling.
    public init(_ rawValue: String) throws(SkillValidationError) {
        guard rawValue.hasPrefix(Self.prefix) else {
            throw .invalidDigest(rawValue)
        }
        let hex = rawValue.utf8.dropFirst(Self.prefix.utf8.count)
        guard hex.count == 64, hex.allSatisfy(Self.isLowercaseHexDigit) else {
            throw .invalidDigest(rawValue)
        }
        self.rawValue = rawValue
    }

    /// The SHA-256 digest of raw bytes.
    public static func sha256(of bytes: some DataProtocol) -> SkillDigest {
        let hash = SHA256.hash(data: bytes)
        var hex = Self.prefix
        hex.reserveCapacity(Self.prefix.utf8.count + 64)
        for byte in hash {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return SkillDigest(validated: hex)
    }

    public var description: String { rawValue }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}

extension SkillDigest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: error.description
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
