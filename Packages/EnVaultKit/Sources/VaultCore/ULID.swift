import Foundation
import Security

/// Universally Unique Lexicographically Sortable Identifier.
/// 48-bit millisecond timestamp + 80 bits of randomness, Crockford base32, 26 chars.
/// Used for revision ids: sorting the strings sorts by time, ties are unique.
public struct ULID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let string: String

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let decodeMap: [Character: UInt8] = {
        var m: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() {
            m[c] = UInt8(i)
            m[Character(c.lowercased())] = UInt8(i)
        }
        // Crockford confusables
        m["O"] = 0; m["o"] = 0; m["I"] = 1; m["i"] = 1; m["L"] = 1; m["l"] = 1
        return m
    }()

    /// Monotonic generator state: within one millisecond the random part is
    /// incremented, so ids made in quick succession on one device still sort
    /// in creation order.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMs: UInt64 = 0
    nonisolated(unsafe) private static var lastRandom = [UInt8](repeating: 0, count: 10)

    /// A new id for "now", monotonic within this process. Pass an explicit
    /// `date` only for tests/fixtures; such ids are not clamped.
    public init(date: Date? = nil) {
        var ms = UInt64(max(0, (date ?? Date()).timeIntervalSince1970 * 1000))
        var random = [UInt8](repeating: 0, count: 10)
        ULID.lock.lock()
        // Never let time go backwards within this process (clock skew, thread races).
        if date == nil, ms < ULID.lastMs { ms = ULID.lastMs }
        if date == nil, ms == ULID.lastMs {
            random = ULID.lastRandom
            var i = 9
            while i >= 0 {
                if random[i] == 0xff { random[i] = 0; i -= 1 } else { random[i] += 1; break }
            }
        } else {
            _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
            random[0] &= 0x7f // leave headroom so increments never overflow in practice
        }
        if date == nil {
            ULID.lastMs = ms
            ULID.lastRandom = random
        }
        ULID.lock.unlock()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xff) }
        for i in 0..<10 { bytes[6 + i] = random[i] }
        string = ULID.encode(bytes)
    }

    public init?(string: String) {
        guard string.count == 26, string.allSatisfy({ ULID.decodeMap[$0] != nil }) else { return nil }
        // First char must be <= 7 so the 128-bit value doesn't overflow.
        guard let first = ULID.decodeMap[string.first!], first <= 7 else { return nil }
        self.string = string.uppercased()
    }

    public var timestamp: Date {
        var ms: UInt64 = 0
        for c in string.prefix(10) { ms = (ms << 5) | UInt64(ULID.decodeMap[c]!) }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public var description: String { string }
    public static func < (a: ULID, b: ULID) -> Bool { a.string < b.string }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = ULID(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ULID \(s)"))
        }
        self = u
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        // 128 bits -> 26 chars of 5 bits (130 bits, top 2 bits zero).
        var out = [Character](repeating: "0", count: 26)
        var value: (hi: UInt64, lo: UInt64) = (0, 0)
        for i in 0..<8 { value.hi = (value.hi << 8) | UInt64(bytes[i]) }
        for i in 8..<16 { value.lo = (value.lo << 8) | UInt64(bytes[i]) }
        for i in stride(from: 25, through: 0, by: -1) {
            out[i] = alphabet[Int(value.lo & 0x1f)]
            // shift 128-bit value right by 5
            value.lo = (value.lo >> 5) | ((value.hi & 0x1f) << 59)
            value.hi >>= 5
        }
        return String(out)
    }
}
