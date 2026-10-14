import SwiftUI
import LicenseKit

/// Shown when a free user hits a Pro feature.
struct UpgradeSheet: View {
    @Environment(LicenseManager.self) private var licenses
    @Environment(\.dismiss) private var dismiss
    let feature: Feature?
    @State private var key = ""
    @State private var showKeyField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("eVault Pro", systemImage: "sparkles").font(.title2.bold())
            if let f = feature {
                Text("“\(f.title)” is part of eVault Pro.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Feature.allCases.filter { $0.minimumPlan == .pro }, id: \.self) { f in
                    Label(f.title, systemImage: "checkmark.circle.fill").foregroundStyle(.primary)
                }
                Text("One-time purchase. Free updates for a year. The free tier keeps \(Entitlements.freeProjectLimit) projects, folder sync, Touch ID and the editor forever.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }
            if showKeyField {
                TextField("Paste license key (EVL1.…)", text: $key)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                if let e = licenses.lastError { Text(e).foregroundStyle(.red).font(.callout) }
            }
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                if showKeyField {
                    Button("Activate") { if licenses.apply(key) { dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(key.isEmpty)
                } else {
                    Button("I have a license key") { showKeyField = true }
                    Link(destination: LicenseManager.purchaseURL) { Text("Get Pro") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Settings tab.
struct LicenseSettings: View {
    @Environment(LicenseManager.self) private var licenses
    @State private var key = ""

    var body: some View {
        Form {
            Section("Plan") {
                if let lic = licenses.license {
                    LabeledContent("Plan") { Text(lic.plan.rawValue.capitalized).bold() }
                    LabeledContent("Licensed to") { Text("\(lic.name) <\(lic.email)>") }
                    LabeledContent("Issued") { Text(lic.issuedAt, format: .dateTime.day().month().year()) }
                    if let u = lic.updatesUntil { LabeledContent("Updates until") { Text(u, format: .dateTime.day().month().year()) } }
                    if let x = lic.expiresAt { LabeledContent("Expires") { Text(x, format: .dateTime.day().month().year()) } }
                    Button("Remove License") { licenses.remove() }
                } else {
                    LabeledContent("Plan") { Text(licenses.plan == .free ? "Free" : licenses.plan.rawValue.capitalized) }
                    Text("Free includes \(Entitlements.freeProjectLimit) projects, folder sync, the editor, history and Touch ID.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Get eVault Pro…", destination: LicenseManager.purchaseURL)
                }
            }
            if licenses.license == nil {
                Section("Activate") {
                    TextField("License key (EVL1.…)", text: $key).font(.system(.body, design: .monospaced))
                    HStack {
                        if let e = licenses.lastError { Text(e).foregroundStyle(.red).font(.callout) }
                        Spacer()
                        Button("Activate") { if licenses.apply(key) { key = "" } }.disabled(key.isEmpty)
                    }
                    Text("Keys are verified on this Mac with a public key. No account, no server, no phone-home.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
