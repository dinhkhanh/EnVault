import Foundation
import CryptoKit

/// Turns other secret formats into dotenv text: flat JSON (Doppler, `vercel env`,
/// generic), 1Password item JSON (`op item get --format json`), and encrypted
/// `.env.vault` files from dotenv-vault / dotenvx.
public enum EnvImport {
    public enum Format: Equatable, Sendable {
        case dotenv
        case json
        case dotenvVault
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notAnObject
        case noUsableFields
        case badDotenvKey
        case environmentMissing(String)
        case decryptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAnObject: "The JSON is not an object of KEY: value pairs."
            case .noUsableFields: "No KEY: value pairs found."
            case .badDotenvKey: "That is not a DOTENV_KEY (expected dotenv://:key_…@dotenvx.com/vault/.env.vault?environment=…)."
            case .environmentMissing(let e): "The .env.vault has no DOTENV_VAULT_\(e.uppercased()) entry."
            case .decryptFailed(let e): "Could not decrypt the \(e) environment: wrong DOTENV_KEY?"
            }
        }
    }

    public static func detect(text: String, fileName: String) -> Format {
        let name = fileName.lowercased()
        if name.hasSuffix(".env.vault") || name == ".env.vault" { return .dotenvVault }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".json") || t.hasPrefix("{") { return .json }
        if DotEnv.parse(text).entries.contains(where: { $0.key.hasPrefix("DOTENV_VAULT_") }) { return .dotenvVault }
        return .dotenv
    }

    // MARK: JSON

    /// A flat object (`{"KEY": "value", "PORT": 3000}`) or a 1Password item
    /// (`{"fields": [{"label": "KEY", "value": "…"}]}`) as dotenv text.
    public static func dotenv(fromJSON text: String) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw ImportError.notAnObject }
        var pairs: [(String, String)] = []
        if let fields = obj["fields"] as? [[String: Any]] {
            for f in fields {
                guard let label = (f["label"] as? String) ?? (f["id"] as? String), let value = scalar(f["value"]), !value.isEmpty else { continue }
                // 1Password's built-in note field is not a variable.
                if (f["purpose"] as? String) == "NOTES" { continue }
                pairs.append((envKey(label), value))
            }
        } else {
            for k in obj.keys.sorted() {
                guard let v = scalar(obj[k]) else { continue }
                pairs.append((envKey(k), v))
            }
        }
        pairs = pairs.filter { DotEnv.isValidKey($0.0) }
        guard !pairs.isEmpty else { throw ImportError.noUsableFields }
        return pairs.map { DotEnv.serialize(EnvEntry(key: $0.0, value: $0.1)) }.joined(separator: "\n") + "\n"
    }

    private static func scalar(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            // JSONSerialization bridges booleans to NSNumber too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    /// "api key" → "API_KEY"; keys that are already valid are kept as written.
    static func envKey(_ label: String) -> String {
        if DotEnv.isValidKey(label) { return label }
        let mapped = label.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        var s = String(mapped)
        if let f = s.first, f.isNumber { s = "_" + s }
        return s
    }

    // MARK: .env.vault

    public struct DotenvKey: Equatable, Sendable {
        public var key: SymmetricKey
        public var environment: String
        public static func == (a: DotenvKey, b: DotenvKey) -> Bool {
            a.environment == b.environment && a.key.withUnsafeBytes { Data($0) } == b.key.withUnsafeBytes { Data($0) }
        }
    }

    /// Parses `dotenv://:key_<64 hex>@dotenvx.com/vault/.env.vault?environment=production`.
    public static func parseDotenvKey(_ s: String) throws -> DotenvKey {
        guard let url = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let password = url.password, password.hasPrefix("key_"),
              let env = url.queryItems?.first(where: { $0.name == "environment" })?.value, !env.isEmpty
        else { throw ImportError.badDotenvKey }
        let hex = String(password.dropFirst(4).suffix(64))
        guard hex.count == 64, let bytes = Data(hex: hex) else { throw ImportError.badDotenvKey }
        return DotenvKey(key: SymmetricKey(data: bytes), environment: env)
    }

    /// Decrypts one environment of a `.env.vault` file. Each `DOTENV_VAULT_<ENV>`
    /// value is base64(nonce[12] ‖ ciphertext ‖ tag[16]), AES-256-GCM.
    public static func decryptVault(_ vaultText: String, key: DotenvKey) throws -> String {
        let name = "DOTENV_VAULT_" + key.environment.uppercased()
        guard let blob = DotEnv.parse(vaultText).values[name] else { throw ImportError.environmentMissing(key.environment) }
        guard let data = Data(base64Encoded: blob), data.count > 28,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key.key)
        else { throw ImportError.decryptFailed(key.environment) }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Environments a `.env.vault` file contains, lowercased (`production`, `development`, …).
    public static func vaultEnvironments(_ vaultText: String) -> [String] {
        DotEnv.parse(vaultText).entries.compactMap { e in
            e.key.hasPrefix("DOTENV_VAULT_") ? String(e.key.dropFirst("DOTENV_VAULT_".count)).lowercased() : nil
        }
    }
}

extension Data {
    init?(hex: String) {
        var out = Data(capacity: hex.count / 2)
        var it = hex.makeIterator()
        while let a = it.next() {
            guard let b = it.next(), let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            out.append(byte)
        }
        self = out
    }
}
