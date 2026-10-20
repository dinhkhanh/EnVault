import SwiftUI
import VaultCore

extension TeamRole {
    var title: String {
        switch self { case .owner: "Owner"; case .admin: "Admin"; case .member: "Member"; case .viewer: "Viewer" }
    }
    /// Roles an owner or admin can give.
    static let assignable: [TeamRole] = [.admin, .member, .viewer]
}

/// Shown under the vault switcher when a team vault is selected: where this
/// person stands, and the way to its people.
struct TeamVaultBar: View {
    @Environment(AppModel.self) private var model
    let session: VaultSession
    @State private var showMembers = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2").foregroundStyle(.secondary)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button {
                showMembers = true
            } label: {
                if let n = session.team?.pending.count, n > 0, session.team?.canManage == true {
                    Text("Members (\(n) waiting)")
                } else {
                    Text("Members")
                }
            }
            .buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $showMembers) { TeamMembersView(session: session) }
    }

    private var status: String {
        guard let team = session.team else { return "Team vault" }
        switch team.access {
        case .locked: return "Locked"
        case .notMember: return team.hasRequestedToJoin ? "Waiting for approval" : "Not a member"
        case .awaitingKey: return "Approved, waiting for the key"
        case .removed: return "You were removed"
        case .member(let role): return team.needsRotation ? "Saving paused: key rotation pending" : role.title
        }
    }
}

/// A team vault's people (FR-6 to FR-12): this person's access, the members
/// and their roles, join requests to approve, and invites.
struct TeamMembersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession
    @State private var approving: PendingMember?
    @State private var removing: TeamMember?
    @State private var leaving = false
    @State private var inviteEmail = ""
    @State private var inviteLink: URL?
    @State private var inviting = false
    @State private var showLog = false
    @State private var inviteRole: TeamRole = .member
    @State private var exporting = false
    @State private var newOwner: TeamMember?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let team = session.team {
                    statusSection(team)
                    if team.canManage, !team.lateEvents.isEmpty { lateSection(team) }
                    if !team.exposed.isEmpty { rotateSection(team) }
                    if team.canManage, !team.pending.isEmpty {
                        Section("Asking to Join") { ForEach(team.pending) { pendingRow($0) } }
                    }
                    Section("Members") { ForEach(team.members) { memberRow($0, team: team) } }
                    agentSection(team)
                    if session.mode == .folder {
                        if team.canManage { folderInviteSection }
                    } else if session.hostsShare, model.teamVaultsAvailable {
                        inviteSection
                    }
                    Section {
                        Button("Membership Log…") { showLog = true }
                        if team.canManage { Button("Export as a Personal Vault…") { exporting = true } }
                        Button("Leave This Team Vault…", role: .destructive) { leaving = true }
                            .disabled(team.role == .owner)
                    } footer: {
                        if team.role == .owner { Text("The owner can't leave: make an admin the owner first.").font(.caption) }
                        if session.hostsShare, team.role != .owner {
                            Text("This vault lives in your iCloud. If you leave, the others keep it, but nobody can invite or take people off the iCloud share any more.").font(.caption)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let e = model.errorMessage { Text(e).font(.callout).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 540, height: 600)
        .sheet(item: $approving) { ApproveMemberSheet(session: session, pending: $0) }
        .sheet(isPresented: $showLog) { MembershipLogView(session: session) }
        .sheet(isPresented: $exporting) { ExportTeamVaultSheet(session: session) }
        .confirmationDialog("Make \(newOwner?.name ?? "this admin") the owner?", isPresented: Binding(get: { newOwner != nil }, set: { if !$0 { newOwner = nil } }), presenting: newOwner) { m in
            Button("Make Owner") { Task { await model.transferOwnership(to: m.id, in: session) } }
        } message: { _ in
            Text("You become an admin. The team's billing moves with a new license in their name."
                 + (session.hostsShare ? " The vault stays in your iCloud, so keep this Mac signed in and don't leave it." : ""))
        }
        .confirmationDialog("Remove \(removing?.name ?? "this member")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { m in
            Button("Remove", role: .destructive) { Task { await model.remove(m.id, from: session) } }
        } message: { _ in
            Text("They lose access to anything saved from now on; the team key is rotated. What they already synced stays on their Macs, so rotate the secrets they could read."
                 + (session.mode == .folder ? " Also take away their access to the shared folder: until then they can still add files, which every Mac ignores." : ""))
        }
        .confirmationDialog("Leave “\(session.name)”?", isPresented: $leaving) {
            Button("Leave", role: .destructive) { Task { await model.leave(session); dismiss() } }
        } message: {
            Text("This Mac's copy is deleted. An admin has to approve you again to come back.")
        }
    }

    @ViewBuilder private func statusSection(_ team: VaultSession.TeamSnapshot) -> some View {
        switch team.access {
        case .notMember, .removed:
            Section("Your Access") {
                Text(team.access == .removed ? "You were removed from this vault." : team.hasRequestedToJoin
                     ? "You asked to join. An owner or admin approves you after comparing this safety code with you:"
                     : "You are not a member of this vault.")
                if team.hasRequestedToJoin, let code = model.identity?.safetyCode {
                    Text(code).font(.title3.monospaced()).textSelection(.enabled)
                }
            }
        case .awaitingKey:
            Section("Your Access") { Text("You're approved. The team key arrives when an admin's Mac syncs.") }
        case .member(let role):
            if team.needsRotation {
                Section("Your Access") {
                    Text("Someone left or was removed, and the team key hasn't been rotated yet. Saving is paused until an admin's Mac syncs.")
                }
            } else if role == .viewer {
                Section("Your Access") { Text("You can read this vault but not change it.") }
            }
        case .locked:
            EmptyView()
        }
    }

    private func lateSection(_ team: VaultSession.TeamSnapshot) -> some View {
        Section("Review") {
            Text("\(team.lateEvents.count) membership change\(team.lateEvents.count == 1 ? "" : "s") arrived after newer ones. That happens when an admin was offline, but check the member list is what you expect.")
            Button("Looks Right") { Task { await model.dismissLateEvents(in: session) } }
        }
    }

    /// FR-23: the team's rules for AI agents. Each member's own setting can only be stricter.
    @ViewBuilder private func agentSection(_ team: VaultSession.TeamSnapshot) -> some View {
        let rules = team.agentRules ?? TeamAgentRules()
        Section {
            if team.canManage {
                Toggle("Allow AI agents", isOn: Binding(get: { rules.enabled }, set: { v in var r = rules; r.enabled = v; Task { await model.setAgentRules(r, in: session) } }))
                Picker("Secret values", selection: Binding(get: { rules.values }, set: { v in var r = rules; r.values = v; Task { await model.setAgentRules(r, in: session) } })) {
                    Text("Never").tag(AIAgents.Policy.Values.never)
                    Text("Ask each time").tag(AIAgents.Policy.Values.ask)
                    Text("As each member's setting allows").tag(AIAgents.Policy.Values.allow)
                }
                .disabled(!rules.enabled)
                Toggle("May change env files", isOn: Binding(get: { rules.writes }, set: { v in var r = rules; r.writes = v; Task { await model.setAgentRules(r, in: session) } }))
                    .disabled(!rules.enabled)
            } else {
                Text(team.agentRules == nil ? "No team rule: your own setting applies." : describe(rules))
            }
        } header: {
            Text("AI Agents")
        } footer: {
            Text("Applies to the envault command and its MCP server in this vault. Each member's own setting (Settings › AI Agents) can only make it stricter. Mark a project or item For People Only from its menu to keep agents away from it entirely.")
                .font(.caption)
        }
    }

    private func describe(_ r: TeamAgentRules) -> String {
        guard r.enabled else { return "AI agents are not allowed in this vault." }
        let values = switch r.values { case .never: "never see values"; case .ask: "need approval for each look at values"; case .allow: "see values as each member's setting allows" }
        return "AI agents \(values) and \(r.writes ? "may" : "may not") change env files."
    }

    /// FR-14: what people who left could read, until each value is changed.
    private func rotateSection(_ team: VaultSession.TeamSnapshot) -> some View {
        Section {
            ForEach(session.items.filter { team.exposed[$0.id] != nil }) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text("\(session.projects.first { $0.id == item.projectId }?.name ?? "") · seen by \(team.exposed[item.id]!.map(team.name).sorted().formatted(.list(type: .and)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") {
                        model.selectedVaultId = session.vaultId == model.personal?.vaultId ? nil : session.vaultId
                        model.selectedToolId = nil
                        model.selectedProjectId = item.projectId
                        model.selectedItemId = item.id
                        dismiss()
                    }
                }
            }
        } header: {
            Text("Secrets to Rotate")
        } footer: {
            Text("People who left could read these values. Issue new ones where they come from and save them here; each drops off this list once changed. In env files, the keys to change are marked.")
                .font(.caption)
        }
    }

    private func pendingRow(_ p: PendingMember) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(p.name ?? "Name not shared with you")
                HStack(spacing: 4) {
                    Text("Asked \(p.requestedAt, style: .relative) ago")
                    if p.inviteLapsed { Text("· invitation lapsed").foregroundStyle(.orange) }
                    else if let role = p.invitedAs { Text("· invited as \(role.title.lowercased())") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Approve…") { approving = p }
        }
    }

    private func memberRow(_ m: TeamMember, team: VaultSession.TeamSnapshot) -> some View {
        let isMe = m.safetyCode == model.identity?.safetyCode
        return HStack {
            VStack(alignment: .leading) {
                Text((m.name ?? "Unnamed") + (isMe ? " (you)" : ""))
                Text(m.safetyCode).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if team.canManage, model.offShare[session.vaultId]?.contains(m.id) == true {
                    Text("Left the iCloud share; remove them to finish").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if team.canManage, m.role != .owner, !isMe {
                Picker("Role", selection: Binding(get: { m.role }, set: { r in Task { await model.setRole(of: m.id, to: r, in: session) } })) {
                    ForEach(TeamRole.assignable, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                if team.role == .owner, m.role == .admin {
                    Button { newOwner = m } label: { Image(systemName: "crown") }
                        .buttonStyle(.borderless).help("Make owner")
                }
                Button(role: .destructive) { removing = m } label: { Image(systemName: "person.badge.minus") }
                    .buttonStyle(.borderless).help("Remove from the vault")
            } else {
                Text(m.role.title).foregroundStyle(.secondary)
            }
        }
    }

    /// Folder mode (FR-6): an invitation file, plus sharing the folder itself.
    private var folderInviteSection: some View {
        Section {
            HStack {
                Picker("Role", selection: $inviteRole) { ForEach(TeamRole.assignable, id: \.self) { Text($0.title).tag($0) } }
                    .fixedSize()
                Spacer()
                Button("Create Invitation File…") {
                    Task {
                        guard let invite = await model.createInvite(role: inviteRole, in: session) else { return }
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "\(session.name).\(TeamInvite.fileExtension)"
                        panel.message = "Save the invitation, then send it to the person you're inviting."
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        do { try invite.encoded().write(to: url, options: .atomic) } catch { model.errorMessage = error.localizedDescription }
                    }
                }
            }
        } header: {
            Text("Invite")
        } footer: {
            Text("Send them the file and share this vault's folder with them (Dropbox, git…) with write access. They open the file in EnVault › Vault › Join Team Vault from Invitation…, then you approve them here after comparing safety codes. The invitation lapses after 7 days.")
                .font(.caption)
        }
    }

    private var inviteSection: some View {
        Section {
            HStack {
                TextField("Apple ID email", text: $inviteEmail).textContentType(.emailAddress)
                Button("Invite") {
                    inviting = true
                    Task {
                        inviteLink = await model.invite(email: inviteEmail.trimmingCharacters(in: .whitespaces), to: session)
                        if inviteLink != nil { inviteEmail = "" }
                        inviting = false
                    }
                }
                .disabled(inviting || !inviteEmail.contains("@"))
            }
            if let inviteLink {
                HStack {
                    Text(inviteLink.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(inviteLink.absoluteString, forType: .string)
                    }
                }
            }
        } header: {
            Text("Invite")
        } footer: {
            Text("Send them the link. When they open it in EnVault they ask to join, and you approve them here after comparing safety codes and choosing their role.")
                .font(.caption)
        }
    }
}

/// Approving a join request (FR-8): the safety codes are compared first.
struct ApproveMemberSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession
    let pending: PendingMember
    @State private var name = ""
    @State private var role: TeamRole = .member
    @State private var codesMatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve \(pending.name ?? "this person")").font(.headline)
            Text("Ask them to read the safety code shown in their EnVault, on a call or in person. Approve only if it matches:")
                .font(.callout).foregroundStyle(.secondary)
            Text(pending.safetyCode).font(.title2.monospaced()).textSelection(.enabled)
            if pending.inviteLapsed {
                Text("They answered an invitation that has lapsed. Send them a new one.").font(.callout).foregroundStyle(.orange)
            } else if let offered = pending.invitedAs {
                // Anyone who can write to the folder can name an open invitation, so the role is the admin's call.
                Text("The invitation offered \(offered.title.lowercased()). Choose the role yourself.").font(.callout).foregroundStyle(.secondary)
            } else if session.mode == .folder {
                Text("This request doesn't name an invitation.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("They read me the same code", isOn: $codesMatch)
            Form {
                TextField("Name in this vault", text: $name)
                Picker("Role", selection: $role) { ForEach(TeamRole.assignable, id: \.self) { Text($0.title).tag($0) } }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Approve") {
                    Task { await model.approve(pending, name: name.trimmingCharacters(in: .whitespaces), role: role, in: session) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!codesMatch || pending.inviteLapsed || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear {
            name = pending.name ?? ""
            // Never preselect more than member: the safety code identifies the person, not the invitation.
            role = min(pending.invitedAs ?? .member, .member)
        }
    }
}

/// New team vault (FR-3). Also creates the Team identity on first use.
struct NewTeamVaultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var myName = NSFullUserName()
    @State private var working = false
    @State private var folder: URL?
    @State private var useFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Team Vault").font(.headline)
            Text("A vault you share with your team through iCloud. Everything in it is encrypted on your Macs; Apple sees only ciphertext.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Vault name (e.g. Acme)", text: $title).textFieldStyle(.roundedBorder)
            Picker("Where", selection: $useFolder) {
                Text("iCloud").tag(false).disabled(!model.teamVaultsAvailable)
                Text("A shared folder (Dropbox, git…)").tag(true)
            }
            .pickerStyle(.radioGroup)
            if useFolder {
                HStack {
                    Text(folder?.path(percentEncoded: false) ?? "No folder chosen").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { folder = Self.chooseEmptyFolder() }
                }
            }
            if model.identity == nil {
                TextField("Your name, as teammates see it", text: $myName).textFieldStyle(.roundedBorder)
            }
            if let e = model.errorMessage, working == false { Text(e).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    working = true
                    Task {
                        if model.identity == nil { await model.createIdentity(name: myName.trimmingCharacters(in: .whitespaces)) }
                        let ok = await model.createTeamVault(title: title.trimmingCharacters(in: .whitespaces), folder: useFolder ? folder : nil)
                        working = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty || (useFolder && folder == nil)
                          || (model.identity == nil && myName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20).frame(width: 400)
        .task {
            model.errorMessage = nil
            useFolder = !model.teamVaultsAvailable
            await model.loadIdentity()
        }
    }

    static func chooseEmptyFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose an empty folder that your team shares (in Dropbox, a git repository…)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard entries.allSatisfy({ $0.hasPrefix(".") }) else {
            let alert = NSAlert()
            alert.messageText = "Choose an empty folder"
            alert.informativeText = "“\(url.lastPathComponent)” already has files in it."
            alert.runModal()
            return nil
        }
        return url
    }
}

/// A share link arrived before this person had a Team identity.
struct JoinIdentitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var myName = NSFullUserName()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a Team Vault").font(.headline)
            Text("Choose the name your teammates see. EnVault also creates the keys they share the vault with; they're kept, encrypted, in your own vault.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Your name", text: $myName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Not Now") { model.shareNeedsIdentity = false; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") {
                    Task {
                        await model.createIdentity(name: myName.trimmingCharacters(in: .whitespaces))
                        model.shareNeedsIdentity = false
                        if let share = ShareInbox.shared.take() { await model.acceptShare(share) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(myName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 400)
    }
}

/// Who joined, was approved, changed role, left or was removed, and every
/// key rotation, newest first (FR-19). Ignored changes are listed with why.
struct MembershipLogView: View {
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession

    var body: some View {
        let team = session.team
        VStack(spacing: 0) {
            List(team?.log ?? []) { entry in
                HStack(alignment: .top) {
                    Image(systemName: icon(entry.change)).foregroundStyle(entry.rejected == nil ? Color.secondary : Color.red).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(entry, team: team)).strikethrough(entry.rejected != nil)
                        HStack(spacing: 6) {
                            Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                            if entry.late { Text("arrived late").foregroundStyle(.orange) }
                            if let why = entry.rejected { Text("ignored: \(why)").foregroundStyle(.red) }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 520, height: 520)
    }

    private func text(_ e: TeamLogEntry, team: VaultSession.TeamSnapshot?) -> String {
        let by = team?.name(e.author) ?? "Someone"
        func n(_ id: UUID) -> String { team?.name(id) ?? "someone" }
        switch e.change {
        case .asked(let who): return "\(n(who)) asked to join"
        case .added(let who, let role): return "\(by) approved \(n(who)) as \(role.title.lowercased())"
        case .roleChanged(let who, let role): return "\(by) made \(n(who)) \(role == .admin ? "an" : "a") \(role.title.lowercased())"
        case .removed(let who): return "\(by) removed \(n(who))"
        case .left(let who): return "\(n(who)) left"
        case .rotated: return "\(by) rotated the team key"
        case .named(let who): return who == e.author ? "\(by) set their name" : "\(by) named \(n(who))"
        case .titled: return "\(by) named the vault"
        case .agentRules(let r): return "\(by) set the rules for AI agents" + (r.enabled ? "" : " (not allowed)")
        case .humansOnly(_, let on): return on ? "\(by) marked something for people only" : "\(by) opened something to AI agents again"
        case .invited(let role): return "\(by) sent an invitation (as \(role.title.lowercased()))"
        case .ownershipTransferred(let to): return "\(by) made \(n(to)) the owner"
        }
    }

    private func icon(_ c: TeamLogEntry.Change) -> String {
        switch c {
        case .asked: "hand.raised"
        case .added: "person.badge.plus"
        case .roleChanged: "person.badge.key"
        case .removed, .left: "person.badge.minus"
        case .rotated: "key"
        case .named, .titled: "pencil"
        case .agentRules, .humansOnly: "cpu"
        case .invited: "envelope"
        case .ownershipTransferred: "crown"
        }
    }
}

/// Vault › Join Team Vault from Invitation…: the invitation file, then the
/// shared folder it is for (FR-6).
@MainActor
enum JoinFromInvitation {
    static func run(_ model: AppModel) {
        let file = NSOpenPanel()
        file.allowedContentTypes = []
        file.allowsOtherFileTypes = true
        file.message = "Choose the invitation file (.\(TeamInvite.fileExtension)) you were sent."
        file.prompt = "Open Invitation"
        guard file.runModal() == .OK, let url = file.url else { return }
        let invite: TeamInvite
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            invite = try TeamInvite.decode(try Data(contentsOf: url))
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        guard let folder = chooseFolder(for: invite.title ?? "the team vault") else { return }
        Task { await model.join(invite, folder: folder) }
    }

    static func chooseFolder(for name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the shared folder that holds \(name) on this Mac."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// FR-30: the team vault's projects, with history, into a new personal vault
/// with its own passphrase.
struct ExportTeamVaultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: VaultSession
    @State private var folder: URL?
    @State private var pass1 = ""
    @State private var pass2 = ""
    @State private var working = false
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export “\(session.name)” as a Personal Vault").font(.headline)
            if done {
                Text("Done. Open it from the Vault menu when you need it, and create a recovery key for it in Settings.").font(.callout)
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Every project and its history, re-encrypted under a new passphrase. Nobody else on the team can open the copy.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(folder?.path(percentEncoded: false) ?? "No folder chosen").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { folder = NewTeamVaultSheet.chooseEmptyFolder() }
                }
                SecureField("Passphrase (8 characters or more)", text: $pass1)
                SecureField("Confirm passphrase", text: $pass2)
                if let e = model.errorMessage { Text(e).font(.callout).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export") {
                        guard let folder else { return }
                        working = true
                        Task {
                            done = await model.exportTeamVault(session, to: folder, passphrase: pass1)
                            working = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || folder == nil || pass1.count < 8 || pass1 != pass2)
                }
            }
        }
        .padding(20).frame(width: 440)
        .task { model.errorMessage = nil }
    }
}
