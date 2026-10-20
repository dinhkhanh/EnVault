import Foundation
import CryptoKit
import LicenseKit

// Vendor-side tool: generate the signing keypair once, then issue keys.
// Hook it to your store's webhook (Lemon Squeezy / Paddle / Gumroad) or run by hand.

let usage = """
usage: envault-license <command>

  keygen                                   print a new Ed25519 keypair (base64)
  issue --email E --name N [--plan pro|team] [--seats N] [--updates-until YYYY-MM-DD] [--expires YYYY-MM-DD]
                                           sign a license; private key from $ENVAULT_LICENSE_PRIVATE_KEY
  verify <key>                             check a key; public key from $ENVAULT_LICENSE_PUBLIC_KEY
"""

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func opt(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f }()

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage) }

switch cmd {
case "keygen":
    let k = Curve25519.Signing.PrivateKey()
    print("ENVAULT_LICENSE_PRIVATE_KEY=\(k.rawRepresentation.base64EncodedString())")
    print("ENVAULT_LICENSE_PUBLIC_KEY=\(k.publicKey.rawRepresentation.base64EncodedString())")
    print("# Keep the private key in a password manager / CI secret. Put the public key in Packages/EnVaultKit/Sources/LicenseKit/VendorKey.swift.")

case "issue":
    guard let pk = ProcessInfo.processInfo.environment["ENVAULT_LICENSE_PRIVATE_KEY"], let raw = Data(base64Encoded: pk),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("set ENVAULT_LICENSE_PRIVATE_KEY") }
    guard let email = opt("--email", args), let name = opt("--name", args) else { fail(usage) }
    let plan = Plan(rawValue: opt("--plan", args) ?? "pro") ?? .pro
    let seats = Int(opt("--seats", args) ?? "1") ?? 1
    let updates = opt("--updates-until", args).flatMap(dateFmt.date(from:))
    let expires = opt("--expires", args).flatMap(dateFmt.date(from:))
    let lic = License(email: email, name: name, plan: plan, updatesUntil: updates, expiresAt: expires, seats: seats)
    print(try LicenseCodec.encode(lic, signingKey: key))

case "verify":
    guard args.count == 2 else { fail(usage) }
    guard let pub = ProcessInfo.processInfo.environment["ENVAULT_LICENSE_PUBLIC_KEY"] else { fail("set ENVAULT_LICENSE_PUBLIC_KEY") }
    do {
        let lic = try LicenseVerifier(publicKeyBase64: pub).verify(args[1])
        print("valid: \(lic.plan.rawValue) for \(lic.name) <\(lic.email)>, \(lic.seats) seat(s), issued \(dateFmt.string(from: lic.issuedAt))")
    } catch {
        fail("invalid: \(error.localizedDescription)")
    }

default:
    fail(usage)
}
