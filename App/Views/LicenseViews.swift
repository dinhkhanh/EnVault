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
                LicenseKeyField(key: $key, autofocus: true) { if licenses.apply(key) { dismiss() } }
            }
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                if showKeyField {
                    Button("Activate") { if licenses.apply(key) { dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(key.isEmpty)
                } else {
                    Button("I have a license key") { licenses.lastError = nil; showKeyField = true }
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
                    LabeledContent("Plan") { Text(licenses.plan.rawValue.capitalized).bold() }
                    LabeledContent("Licensed to") { Text("\(lic.name) <\(lic.email)>") }
                    LabeledContent("Issued") { Text(lic.issuedAt, format: .dateTime.day().month().year()) }
                    if let u = lic.updatesUntil { LabeledContent("Updates until") { Text(u, format: .dateTime.day().month().year()) } }
                    if let x = lic.expiresAt { LabeledContent("Expires") { Text(x, format: .dateTime.day().month().year()) } }
                    if let n = licenses.updatesNotice {
                        Text(n).font(.callout).foregroundStyle(.orange)
                        Link("Renew eVault Pro…", destination: LicenseManager.purchaseURL)
                    }
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
                    LicenseKeyField(key: $key) { if licenses.apply(key) { key = "" } }
                    HStack {
                        Spacer()
                        Button("Activate") { if licenses.apply(key) { key = "" } }.disabled(key.isEmpty)
                    }
                    Text("Keys are verified on this Mac with a public key. No account, no server, no phone-home.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Lost your key? Get it by email…", destination: LicenseManager.resendKeyURL).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Multi-line box for pasting a license key. A titled, bordered field with a prose prompt
/// (not a key-shaped placeholder that reads like a value), the whole key visible, and a status
/// line that says whether what's in the box is complete before the user hits Activate.
struct LicenseKeyField: View {
    @Environment(LicenseManager.self) private var licenses
    @Binding var key: String
    var autofocus = false
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    private enum Status { case empty, incomplete, complete, rejected(String) }

    private var status: Status {
        if let e = licenses.lastError { return .rejected(e) }
        if key.isEmpty { return .empty }
        return LicenseCodec.looksLikeKey(key) ? .complete : .incomplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("License key").font(.headline)
                Spacer()
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .controlSize(.small)
                    .help("Paste the key from the clipboard")
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $key)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.trailing, 16)  // room for the clear button
                    .onKeyPress(.return) {
                        if !key.isEmpty { onSubmit() }
                        return .handled
                    }
                if key.isEmpty {
                    Text("Paste the key from your purchase email here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .frame(height: 84)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                if !key.isEmpty {
                    Button { key = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .padding(6)
                        .help("Clear")
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(borderColor, lineWidth: focused ? 2 : 1))
            statusLine.font(.callout)
        }
        .onChange(of: key) { _, new in
            // Mail clients wrap long keys; whitespace is never part of one.
            let n = LicenseCodec.normalize(new)
            if n != new { key = n }
            licenses.lastError = nil
        }
        .onAppear { if autofocus { focused = true } }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .empty:
            Label("Starts with EVL1. and is one long line. Copy all of it.", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .incomplete:
            Label("Looks incomplete. Make sure you copied the whole key.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .complete:
            Label("Key looks complete. Activate to verify it on this Mac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var borderColor: Color {
        switch status {
        case .empty, .complete: focused ? .accentColor : Color(nsColor: .separatorColor)
        case .incomplete: .orange
        case .rejected: .red
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { key = LicenseCodec.normalize(s) }
        focused = true
    }
}
