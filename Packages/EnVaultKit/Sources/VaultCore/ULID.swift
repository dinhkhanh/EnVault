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
    /// in creation order. Ids dated ahead (`init(notBefore:)`) keep their own,
    /// so they never move this process's other ids forward.
    private static let lock = NSLock()
    private struct Sequence { var ms: UInt64 = 0; var random = [UInt8](repeating: 0, count: 10) }
    nonisolated(unsafe) private static var now = Sequence()
    nonisolated(unsafe) private static var ahead = Sequence()

    /// A new id for "now", monotonic within this process. Pass an explicit
    /// `date` only for tests/fixtures; such ids are not clamped.
    public init(date: Date? = nil) {
        if let date {
            self.init(ms: Self.ms(date), random: Self.freshRandom())
        } else {
            self.init(next: &ULID.now, ms: Self.ms(Date()))
        }
    }

    /// A new id for now or `floor`, whichever is later; monotonic like `init()`.
    public init(notBefore floor: Date) {
        let now = Date()
        if floor <= now { self.init() } else { self.init(next: &ULID.ahead, ms: Self.ms(floor)) }
    }

    private init(next seq: inout Sequence, ms: UInt64) {
        var ms = ms, random: [UInt8]
        ULID.lock.lock()
        // Never let time go backwards within this process (clock skew, thread races).
        if ms < seq.ms { ms = seq.ms }
        if ms == seq.ms {
            random = seq.random
            var i = 9
            while i >= 0 {
                if random[i] == 0xff { random[i] = 0; i -= 1 } else { random[i] += 1; break }
            }
        } else {
            random = Self.freshRandom()
        }
        seq = Sequence(ms: ms, random: random)
        ULID.lock.unlock()
        self.init(ms: ms, random: random)
    }

    private init(ms: UInt64, random: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xff) }
        for i in 0..<10 { bytes[6 + i] = random[i] }
        string = ULID.encode(bytes)
    }

    private static func ms(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1000)) }

    private static func freshRandom() -> [UInt8] {
        var random = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        random[0] &= 0x7f // leave headroom so increments never overflow in practice
        return random
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
