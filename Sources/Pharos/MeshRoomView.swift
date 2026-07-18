import SwiftUI
import UniformTypeIdentifiers

/// In-window chat-room pane: the conversation, with a room-switcher dropdown in
/// the title row (rename/delete live in the `…` menu beside it). Reads the
/// per-room transcript JSONL the broker writes, refreshed by the Broker event
/// cursor with a low-frequency recovery poll. The
/// human input box at the bottom delivers @mentions for real: a
/// mentioned agent is notified at its next turn boundary via the mesh Stop hook
/// (see MeshHooks). Typing `@` pops a member autocomplete fed by the same
/// `list` poll (↑↓ choose, ⇥/⏎ complete, esc dismiss).
struct MeshRoomView: View {
    /// The room this tab is showing, OWNED by ContentView (per window tab) so
    /// each tab keeps its own room and the tab title tracks it. Empty = none
    /// picked yet (reload seeds the first).
    @Binding var room: String
    @Environment(ProjectStore.self) private var store
    @State private var rooms: [String] = []
    @State private var membersByRoom: [String: [String]] = [:]
    @State private var membersInfoByRoom: [String: [String: MeshMemberInfo]] = [:]
    @State private var messages: [MeshMsg] = []
    @State private var draft: String = ""
    @State private var replyingTo: MeshMsg?
    @State private var pendingAttachments: [MeshAttachment] = []
    @State private var uploadingAttachment = false
    @State private var mentionSel = 0
    @State private var mentionDismissed: String?
    @State private var hoveredMessageID: String?
    @State private var notices: [Notice] = []
    @FocusState private var inputFocused: Bool
    @State private var issueRef: IssueRef?
    @State private var loading = false
    private var membersInfo: [String: MeshMemberInfo] { membersInfoByRoom[room] ?? [:] }
    @State private var resolving = false
    @State private var resolved = false
    private struct IssueRef: Identifiable { let project: String; let number: Int; var id: String { "\(project)#\(number)" } }
    private let recoveryTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        chatPane
        .navigationTitle(PharosViewTitle.rooms)
        // Drop image/PDF files anywhere on the room to attach them (like "+"),
        // instead of the field's default of inserting the file path as text.
        .dropDestination(for: URL.self) { urls, _ in acceptDroppedFiles(urls) }
        .task(id: brokerRouteID) { await resolveRemote() }   // resolve transport BEFORE first load
        .task(id: brokerRouteID + "|events") { await watchEvents() }
        .onReceive(recoveryTick) { _ in reload() }
        .task(id: room) {
            // Rapid switches can leave several detached history reads in
            // flight. Only the room still visible may update the transcript.
            let requested = room
            let loaded = await Self.history(requested)
            guard !Task.isCancelled, room == requested else { return }
            messages = loaded
        }
        .onAppear { draft = MeshRoomDraftCache.draft(for: room) }
        .onChange(of: room) { _, nextRoom in
            draft = MeshRoomDraftCache.draft(for: nextRoom)
        }
        .onChange(of: draft) { _, nextDraft in
            MeshRoomDraftCache.save(nextDraft, for: room)
        }
        // Issue references (project#number) in messages are tappable links.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "pharosissue" else { return .systemAction }
            let parts = url.pathComponents                       // ["/", project, number]
            if parts.count >= 3, let n = Int(parts[2]) {
                issueRef = IssueRef(project: parts[1].removingPercentEncoding ?? parts[1], number: n)
            }
            return .handled
        })
        .sheet(item: $issueRef) { issuePopup($0) }
    }

    /// Turn `project#number` tokens into markdown links on our custom scheme,
    /// so the MarkdownText-rendered message keeps tappable issue references
    /// (caught by this view's `openURL` handler).
    private func linkifyIssueRefs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([A-Za-z0-9._-]+)#([0-9]+)") else { return text }
        let ns = text as NSString
        var result = text
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let proj = ns.substring(with: m.range(at: 1))
            let num = ns.substring(with: m.range(at: 2))
            let enc = proj.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? proj
            let link = "[\(ns.substring(with: m.range))](pharosissue://x/\(enc)/\(num))"
            if let r = Range(m.range, in: result) { result.replaceSubrange(r, with: link) }
        }
        return result
    }

    @ViewBuilder
    private func issuePopup(_ ref: IssueRef) -> some View {
        let issue = store.projects.first { $0.name == ref.project }?.issues.first { $0.number == ref.number }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(ref.project) #\(ref.number)").font(.headline)
                Spacer()
                Button("Done") { issueRef = nil }.keyboardShortcut(.cancelAction)
            }
            if let i = issue {
                HStack(spacing: 6) {
                    Image(systemName: i.status.symbol).foregroundStyle(.secondary)
                    Text(i.status.label).font(.callout).foregroundStyle(.secondary)
                }
                Text(i.title).font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !i.body.isEmpty {
                    ScrollView {
                        Text(i.body).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No issue “\(ref.project)#\(ref.number)” found in this registry.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 440, height: 340)
    }

    // MARK: middle — the conversation

    private var chatPane: some View {
        VStack(spacing: 0) {
            // Room title only — switching/adding/managing rooms lives in the
            // toolbar's chat-room button (RoomsToolbarButton); each window tab
            // is one room.
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.tint)
                Text(room.isEmpty ? "Chat Rooms" : room).font(.headline)
                if !room.isEmpty, let m = membersByRoom[room]?.filter({ $0 != "human" }), !m.isEmpty {
                    Text("· \(m.count) member\(m.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if room.isEmpty {
                ContentUnavailableView("No room open",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick or add a room from the chat-room button in the toolbar."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript
                    .overlay(alignment: .bottomLeading) {
                        if !mentionSuggestions.isEmpty { mentionPopup.padding(10) }
                    }
            }

            Divider()
            noticeBar
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: poke notices — what the human must handle by hand

    private struct Notice: Identifiable { let id = UUID(); let text: String }

    /// Transient per-send feedback: "poked @x", "@y needs you to approve a
    /// dialog", "@z isn't in tmux — nudge it yourself". Auto-expires.
    @ViewBuilder
    private var noticeBar: some View {
        if !notices.isEmpty {
            VStack(spacing: 1) {
                ForEach(notices) { n in
                    HStack(spacing: 6) {
                        Image(systemName: n.text.hasPrefix("⚡") ? "bolt.fill" : "info.circle")
                            .font(.caption).foregroundStyle(n.text.hasPrefix("⚡") ? .green : .orange)
                        Text(n.text).font(.caption).lineLimit(2)
                        Spacer()
                        Button { notices.removeAll { $0.id == n.id } } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.25))
            Divider()
        }
    }

    private func addNotices(_ texts: [String]) {
        for t in texts {
            let n = Notice(text: t)
            notices.append(n)
            Task {   // auto-expire; manual ✕ already removed it → removeAll is a no-op
                try? await Task.sleep(for: .seconds(15))
                notices.removeAll { $0.id == n.id }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, m in row(m) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Messenger-style row: avatar beside a bubble, the human's own messages
    /// right-aligned. The avatar doubles as the member's live status display
    /// (gray = offline/gone, badge dot = busy/blocked/ready).
    private func row(_ m: MeshMsg) -> some View {
        let mine = m.from == "human"
        return HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 60) } else { avatar(m.from) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                // Identity/avatar row — the reply icon lives here, flat, at the
                // outer edge: right of the header for incoming, left for own.
                HStack(spacing: 6) {
                    Text(m.from).font(.caption.weight(.semibold))
                        .foregroundStyle(mine ? Color.secondary : Color.accentColor)
                    if !m.to.isEmpty {
                        Text("→ " + m.to.map { "@\($0)" }.joined(separator: " "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Date(timeIntervalSince1970: m.ts).formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.tertiary)
                    replyButton(for: m)
                }
                .environment(\.layoutDirection, mine ? .rightToLeft : .leftToRight)
                // Full markdown body (Wick-derived MarkdownText — same renderer
                // as issue bodies), with project#number kept tappable.
                VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                    if let reply = m.replyTo { replyCard(reply) }
                    if !m.text.isEmpty {
                        MarkdownText(text: linkifyIssueRefs(m.text)).font(.callout).textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(mine ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                             : AnyShapeStyle(.quaternary.opacity(0.55)),
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    ForEach(m.attachments ?? []) { attachment in
                        Button { openAttachment(attachment) } label: { attachmentCard(attachment) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if mine { avatar(m.from) } else { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .contextMenu {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                replyingTo = m
                inputFocused = true
            }
            Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.setString(m.text, forType: .string) }
        }
    }

    /// Small flat reply icon on the identity row. Forced LTR so the glyph
    /// isn't mirrored inside the header's right-to-left (own-message) layout.
    private func replyButton(for m: MeshMsg) -> some View {
        Button {
            replyingTo = m
            inputFocused = true
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .buttonStyle(.plain)
        .help("Reply")
        .opacity(0.55)
    }

    private func replyCard(_ reply: MeshReply) -> some View {
        HStack(spacing: 7) {
            Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.from == "human" ? "You" : reply.from)
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Text(reply.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 4)
    }

    private func attachmentCard(_ attachment: MeshAttachment) -> some View {
        HStack(spacing: 9) {
            Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext" : "photo")
                .font(.title3).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: 300, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: avatars — Clawd poses ARE the member-status surface

    /// Deterministic per-nick avatar tint (stable across launches/machines).
    private static func nickColor(_ nick: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint, .brown]
        return palette[stableHash(nick) % palette.count]
    }

    /// djb2 — Swift's `hashValue` is seed-randomized per launch, so pose/color
    /// picks would flicker across restarts (and differ between the two Macs).
    private static func stableHash(_ s: String) -> Int {
        abs(s.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) })
    }

    /// busy → working, blocked → needs the human, stopped/idle → poke-ready,
    /// registered-but-silent (e.g. right after a broker restart) → gray dot:
    /// the member is PRESENT, its state just hasn't been re-reported yet —
    /// without the gray dot this read as "offline" (user confusion 2026-07-11).
    private static func statusDot(_ state: String?) -> Color? {
        switch state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: .orange
        case .blocked: .red
        case .stopped, .idle: .green
        case .gone: nil
        case nil: .gray
        }
    }

    /// Per-state pose pools, one set per agent KIND. The nick hash picks a
    /// stable variant, so each agent keeps its own working/idle pose — identity
    /// through pose + tint, live status through the pool. Claude agents wear the
    /// Clawd set (from the user's clawd-watchface project); Codex agents wear a
    /// blue-robot set with a `>_` terminal face. Both pre-cropped into
    /// Resources/Avatars (`clawd-*` / `codex-*`).
    private static let clawdPools: [MeshSessionState: [String]] = [
        .busy: ["working-thinking", "working-building", "working-juggling",
                "working-typing", "working-wizard", "working-debugger",
                "working-carrying", "working-conducting", "working-sweeping",
                "working-ultrathink"],
        .stopped: ["idle-reading", "idle-look", "idle-living", "idle-follow", "happy"],
        .idle: ["idle-doze", "idle-yawn"],
        .blocked: ["mini-alert", "error", "notification", "react-annoyed"],
        .gone: ["sleeping", "collapse-sleep"],
    ]
    private static let codexPools: [MeshSessionState: [String]] = [
        .busy: ["working", "typing", "walk"],
        .stopped: ["idle", "wave", "happy", "sparkle", "love"],
        .idle: ["coffee", "reading", "sing"],
        .blocked: ["alert", "think"],
        .gone: ["sleep", "away"],
    ]

    /// The full pose asset basename (with kind prefix) for a member, e.g.
    /// `codex-working` / `clawd-idle-doze`. Unknown state → the kind's neutral base.
    private static func avatarBasename(kind: String?, nick: String, state: MeshSessionState?) -> String {
        let codex = kind == "codex"
        let pools = codex ? codexPools : clawdPools
        let base = codex ? "codex-idle" : "clawd-static-base"
        guard let state, let pool = pools[state], !pool.isEmpty else { return base }
        let pose = pool[stableHash(nick) % pool.count]
        return (codex ? "codex-" : "clawd-") + pose
    }

    /// Where the pose PNGs may live. NEVER `Bundle.module`: its generated
    /// accessor only checks the .app ROOT (not Contents/Resources) plus the
    /// build machine's absolute `.build` path — and `fatalError`s when both
    /// miss, which crashed the app on any Mac without the repo checkout
    /// (observed on home-ts, 2026-07-11). Plain file probing can't crash.
    private static let clawdSearchURLs: [URL] = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL {
            candidates.append(r.appendingPathComponent("Avatars", isDirectory: true))              // .app: raw Resources copy
            candidates.append(r.appendingPathComponent("Pharos_Pharos.bundle", isDirectory: true)) // .app: SwiftPM bundle (flat)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Pharos_Pharos.bundle", isDirectory: true)) // swift build/run
        return candidates
    }()

    nonisolated(unsafe) private static var avatarCache: [String: NSImage] = [:]
    /// Bundled avatar PNG by basename (cached — only ever touched from the
    /// main actor). nil (→ symbol/letter fallback) when the asset is missing.
    private static func avatarAsset(_ name: String) -> NSImage? {
        if let hit = avatarCache[name] { return hit }
        for dir in clawdSearchURLs {
            let url = dir.appendingPathComponent("\(name).png")
            if let img = NSImage(contentsOf: url) {
                avatarCache[name] = img
                return img
            }
        }
        return nil
    }

    /// Pixel avatar on a per-nick tinted circle. The pose tracks the member's
    /// live state (working/idle/dozing/alarmed/asleep) and the sprite set tracks
    /// its agent kind (Claude → Clawd, Codex → blue robot); gray = gone/unknown.
    private func avatar(_ nick: String) -> some View {
        let human = nick == "human"
        let info = membersInfo[nick]
        let state = MeshSessionState(rawValue: info?.state ?? "")
        let offline = !human && (info == nil || state == .gone)
        return Circle()
            .fill(offline ? AnyShapeStyle(Color.gray.opacity(0.22))
                          : AnyShapeStyle((human ? Color.accentColor : Self.nickColor(nick)).opacity(0.25)))
            .frame(width: 34, height: 34)
            .overlay {
                if human {
                    // The human's portrait (user-provided cartoon, head crop).
                    if let img = Self.avatarAsset("human") {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
                    }
                } else if let img = Self.avatarAsset(Self.avatarBasename(kind: info?.kind, nick: nick, state: state)) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)          // keep the pixel art crisp
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .grayscale(offline ? 1 : 0)
                        .opacity(offline ? 0.55 : 1)
                } else {
                    Text(String(nick.prefix(1)).uppercased())   // asset-missing fallback
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !human, !offline, let dot = Self.statusDot(info?.state) {
                    Circle().fill(dot)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
            .help(human ? "you" : "\(nick) — \(info?.state ?? "offline")")
    }

    /// Human input. `@nick` delivers to that agent: it surfaces via the unread
    /// signal at the agent's next turn boundary (Stop hook). No @ = transcript
    /// only. While an `@…` token is being typed, the arrow/tab/return/escape
    /// keys drive the member autocomplete popup instead of the field.
    private var inputBar: some View {
        VStack(spacing: 7) {
            if !mentionableMembers.isEmpty { memberMentionStrip }
            if let replyingTo {
                HStack(spacing: 7) {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(replyingTo.from == "human" ? "yourself" : replyingTo.from)")
                            .font(.caption.weight(.semibold))
                        Text(replyingTo.text.isEmpty ? "Attachment" : replyingTo.text)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingTo = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                // Follow content, but never let a long quote balloon the bar.
                .fixedSize(horizontal: false, vertical: true)
            }
            if !pendingAttachments.isEmpty || uploadingAttachment {
                HStack(spacing: 7) {
                    ForEach(pendingAttachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip")
                            Text(attachment.name).lineLimit(1)
                            Button { pendingAttachments.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    if uploadingAttachment { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                Button(action: chooseAttachment) { Image(systemName: "plus") }
                    .disabled(room.isEmpty || uploadingAttachment)
            TextField("Message the room — @nick to poke someone, plain text broadcasts",
                      text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .onSubmit(send)
                .onKeyPress(.upArrow) { mentionMove(-1) }
                .onKeyPress(.downArrow) { mentionMove(1) }
                .onKeyPress(.tab) { mentionAccept() }
                .onKeyPress(.return) { mentionAccept() }
                .onKeyPress(.escape) {
                    guard !mentionSuggestions.isEmpty else { return .ignored }
                    mentionDismissed = activeMentionToken
                    return .handled
                }
                .onChange(of: draft) { _, _ in
                    mentionSel = 0
                    // An esc-dismissed popup stays hidden only for that token.
                    if let d = mentionDismissed, d != activeMentionToken { mentionDismissed = nil }
                }
                .disabled(room.isEmpty)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(room.isEmpty || (draft.trimmingCharacters(in: .whitespaces).isEmpty && pendingAttachments.isEmpty))
            }
        }
        .padding(10)
    }

    // MARK: @-mention autocomplete

    /// The trailing `@…` token still being typed (nil once whitespace ends it).
    /// Only end-of-draft mentions autocomplete — SwiftUI's TextField exposes no
    /// caret position, and chat composition is effectively always append-at-end.
    private var activeMentionToken: String? {
        guard let last = draft.last, !last.isWhitespace,
              let tok = draft.split(whereSeparator: { $0.isWhitespace }).last,
              tok.hasPrefix("@") else { return nil }
        return String(tok)
    }

    /// Popup rows: the current room's members (from the same `list` poll that
    /// feeds the tab strip) PLUS everyone who has spoken in the loaded
    /// transcript — so @-completion keeps working even when registrations were
    /// lost (e.g. agents that haven't re-joined since a broker restart),
    /// filtered to whatever continues what's typed after `@`.
    private var mentionSuggestions: [String] {
        guard let tok = activeMentionToken, tok != mentionDismissed else { return [] }
        let query = tok.dropFirst().lowercased()
        var pool = membersByRoom[room] ?? []
        for m in messages where !pool.contains(m.from) { pool.append(m.from) }
        pool.removeAll { $0 == "human" }
        pool.removeAll { !isLiveMember($0) }
        let hits = query.isEmpty ? pool : pool.filter { $0.lowercased().hasPrefix(query) }
        return Array(hits.prefix(8))
    }

    /// A member worth @-mentioning: present in the live roster and not gone.
    /// This excludes both explicitly-gone members AND historical senders who
    /// have fully left the room (no roster entry). Guarded so a transient
    /// empty roster doesn't hide everyone.
    private func isLiveMember(_ nick: String) -> Bool {
        let info = membersInfo
        guard !info.isEmpty else { return true }
        guard let member = info[nick] else { return false }
        return MeshSessionState(rawValue: member.state ?? "") != .gone
    }

    /// Live, non-human room members shown as one-tap @-mention chips above the
    /// input (mirrors the iOS member strip).
    private var mentionableMembers: [String] {
        var pool = membersByRoom[room] ?? []
        pool.removeAll { $0 == "human" || !isLiveMember($0) }
        return pool.sorted()
    }

    private func insertMentionChip(_ nick: String) {
        let separator = draft.isEmpty || draft.last == " " ? "" : " "
        draft += "\(separator)@\(nick) "
        inputFocused = true
    }

    private var memberMentionStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mentionableMembers, id: \.self) { nick in
                    Button { insertMentionChip(nick) } label: {
                        HStack(spacing: 5) {
                            if let dot = Self.statusDot(membersInfo[nick]?.state) {
                                Circle().fill(dot).frame(width: 6, height: 6)
                            }
                            Text("@\(nick)").font(.caption)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Mention @\(nick)")
                }
            }
            .padding(.horizontal, 2)
        }
        // A horizontal ScrollView otherwise grabs flexible vertical space and
        // balloons the composer; pin it to the chip row height.
        .frame(height: 28)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func mentionMove(_ delta: Int) -> KeyPress.Result {
        let n = mentionSuggestions.count
        guard n > 0 else { return .ignored }
        mentionSel = ((mentionSel + delta) % n + n) % n
        return .handled
    }

    /// Complete the highlighted suggestion. `.ignored` when no popup is up, so
    /// a plain ⏎ still falls through to `onSubmit` and sends the message.
    private func mentionAccept() -> KeyPress.Result {
        let s = mentionSuggestions
        guard !s.isEmpty else { return .ignored }
        completeMention(s[min(mentionSel, s.count - 1)])
        return .handled
    }

    private func completeMention(_ nick: String) {
        guard let tok = activeMentionToken else { return }
        draft = String(draft.dropLast(tok.count)) + "@\(nick) "
        inputFocused = true               // a mouse pick must not strand focus
    }

    /// Floating member picker, anchored just above the input bar.
    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(mentionSuggestions.enumerated()), id: \.element) { i, nick in
                Button { completeMention(nick) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "at").font(.caption).foregroundStyle(.secondary)
                        Text(nick).font(.callout)
                        Spacer(minLength: 0)
                        if let dot = Self.statusDot(membersInfo[nick]?.state) {
                            Circle().fill(dot).frame(width: 7, height: 7)
                        }
                        Text(membersInfo[nick]?.state ?? "offline")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(i == mentionSel ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ choose · ⇥ or ⏎ complete · esc dismiss")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.top, 2)
        }
        .padding(6)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    // MARK: data

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        uploadFile(at: url)
    }

    /// Upload one file as a pending attachment — shared by the "+" button and
    /// drag-and-drop, so a dropped file behaves exactly like a chosen one.
    private func uploadFile(at url: URL) {
        uploadingAttachment = true
        Task {
            let result = await Task.detached { () -> Result<MeshAttachment, Error> in
                let capabilities = MeshClient.send(MeshRequest(cmd: "capabilities"))
                guard capabilities.capabilities?.contains("attachment-v1") == true else {
                    return .failure(MeshClientError.invalidResponse("Update the Mesh broker before uploading attachments."))
                }
                do { return .success(try MeshClient.uploadAttachment(fileAt: url)) }
                catch { return .failure(error) }
            }.value
            uploadingAttachment = false
            switch result {
            case .success(let attachment): pendingAttachments.append(attachment)
            case .failure(let error): addNotices([error.localizedDescription])
            }
        }
    }

    /// Accept files dropped anywhere on the room — image and PDF only, matching
    /// the "+" picker. Each becomes a pending attachment (not path text).
    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        let accepted = urls.filter { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            else { return false }
            return type.conforms(to: .image) || type.conforms(to: .pdf)
        }
        guard !accepted.isEmpty, !room.isEmpty else { return false }
        for url in accepted { uploadFile(at: url) }
        return true
    }

    private func openAttachment(_ attachment: MeshAttachment) {
        Task {
            let result = await Task.detached { () -> Result<URL, Error> in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PharosMeshAttachments", isDirectory: true)
                    .appendingPathComponent(attachment.id, isDirectory: true)
                let destination = directory.appendingPathComponent(attachment.name)
                do { return .success(try MeshClient.downloadAttachment(id: attachment.id, to: destination)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success(let url): NSWorkspace.shared.open(url)
            case .failure(let error): addNotices([error.localizedDescription])
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !room.isEmpty else { return }
        let r = room
        let reply = replyingTo
        let attachments = pendingAttachments
        draft = ""
        replyingTo = nil
        pendingAttachments = []
        // @tokens in the human text become directed (poke) targets; with no
        // @, `to` stays nil and the broker broadcasts to the whole room (no
        // poke). Shared parser with the CLI `say` so both surfaces match.
        let mentions = MeshHooks.parseTextMentions(text)
        let to = mentions.isEmpty ? nil : mentions
        Task {
            let result = await Task.detached { () -> (sent: Bool, notes: [String]) in
                if reply != nil || !attachments.isEmpty {
                    let capabilities = MeshClient.send(MeshRequest(cmd: "capabilities"))
                    guard capabilities.capabilities?.contains("mesh-v2") == true else {
                        return (false, ["Update the Mesh broker before sending replies or attachments."])
                    }
                }
                var request = MeshRequest(cmd: "say", room: r, nick: "human", text: text, to: to)
                request.replyToID = reply?.stableID
                request.attachments = attachments.isEmpty ? nil : attachments
                let resp = MeshClient.send(request)
                if !resp.ok { return (false, [resp.error ?? "Message could not be sent."]) }
                return (true, [])
            }.value
            if !result.sent {
                draft = text
                replyingTo = reply
                pendingAttachments = attachments
            }
            addNotices(result.notes)
        }
    }

    /// Poll the broker (which may be REMOTE over TCP — see MeshClient) for the
    /// room list + the current room's history. Runs the blocking socket calls
    /// off the main thread and applies results on the main actor. The `loading`
    /// guard drops overlapping ticks so a slow remote round-trip can't pile up.
    private func reload() {
        guard resolved, !loading, !resolving else { return }   // wait for transport to be resolved
        loading = true
        let selected = room
        Task {
            let snap = await Self.fetch(selected: selected)
            loading = false
            // Remote broker unreachable (e.g. peer daemon died) → re-bootstrap.
            if !snap.ok && MeshClient.remoteEndpoint != nil { await resolveRemote(); return }
            rooms = snap.rooms
            membersByRoom = snap.members
            membersInfoByRoom = snap.info
            // The user may have switched rooms while this remote query was in
            // flight. Keep its metadata, but never navigate the tab back or
            // replace the new room's transcript with the stale selection.
            guard room == selected else { return }
            room = snap.pick
            messages = snap.messages
        }
    }

    /// Broker-held long poll: idle connections consume no refresh traffic and
    /// return as soon as a message/roster event is published. History remains
    /// authoritative, so every event simply triggers the existing snapshot
    /// reload and a 30-second recovery poll covers disconnections.
    private func watchEvents() async {
        while !Task.isCancelled && !resolved {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        var cursor: UInt64?
        while !Task.isCancelled {
            let currentCursor = cursor
            let response = await Task.detached {
                MeshClient.events(after: currentCursor, timeoutMs: 25_000)
            }.value
            guard !Task.isCancelled else { return }
            if response.ok, let next = response.cursor {
                cursor = next
                if !(response.events ?? []).isEmpty { reload() }
            } else {
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var brokerRouteID: String {
        let hosts = store.executionHosts.map { "\($0.id.uuidString):\($0.sshHost)" }.joined(separator: ",")
        return "\(store.meshServerEndpoint)|\(hosts)|\(store.isMeshHub)"
    }

    /// Point MeshClient at the explicitly configured Broker. The SSH Host
    /// lookup below is only a migration bridge for pre-Broker configurations.
    /// SSHing (off-main) to discover the peer's Tailscale IP and ensure its
    /// broker is up. nil result ⇒ use the local broker. Runs before the first
    /// load, whenever the peer host changes, and to self-heal a dead remote.
    private func resolveRemote() async {
        guard !resolving else { return }
        resolving = true
        if let endpoint = store.validMeshServerEndpoint {
            MeshClient.remoteEndpoint = endpoint
            MeshPaths.setDialEndpointFile(endpoint)
            resolving = false
            resolved = true
            reload()
            return
        }
        let peer = store.peerHost
        let hub = store.isMeshHub
        let ep = await Task.detached { MeshRemote.resolve(peerHost: peer, isHub: hub) }.value
        MeshClient.remoteEndpoint = ep
        // Persist for CLI/hooks on this machine (Pharos#5 P3): satellite agents
        // read the mesh-endpoint file and follow the hub with zero env config.
        // Fail-open: a satellite whose peer is transiently unreachable keeps the
        // last-known endpoint file instead of islanding its agents onto a local
        // broker. The hub (and an unpaired Mac) does clear the file — it serves
        // locally by design.
        if hub || peer.isEmpty || ep != nil { MeshPaths.setDialEndpointFile(ep) }
        resolving = false
        resolved = true
        reload()
    }

    private struct Snapshot {
        let ok: Bool; let rooms: [String]; let members: [String: [String]]
        let info: [String: [String: MeshMemberInfo]]
        let pick: String; let messages: [MeshMsg]
    }

    /// Off-main broker query: room list (names + members, feeding the tab strip
    /// and the @-autocomplete), the presence roster (avatar states), then
    /// history for the room that stays selected (or the first, if
    /// none/deleted). `ok` reflects broker reachability.
    private static func fetch(selected: String) async -> Snapshot {
        await Task.detached {
            let listResp = MeshClient.send(MeshRequest(cmd: "list"))
            let infos = listResp.rooms ?? []
            let names = infos.map(\.name).sorted()
            let members = Dictionary(infos.map { ($0.name, $0.members) }, uniquingKeysWith: { a, _ in a })
            let roster = MeshClient.send(MeshRequest(cmd: "who")).members ?? []
            var info: [String: [String: MeshMemberInfo]] = [:]
            for member in roster {
                for room in member.rooms { info[room, default: [:]][member.nick] = member }
            }
            let pick = selected.isEmpty || !names.contains(selected) ? (names.first ?? "") : selected
            let msgs: [MeshMsg] = pick.isEmpty ? []
                : (MeshClient.send(MeshRequest(cmd: "history", room: pick, limit: 200)).messages ?? [])
            return Snapshot(ok: listResp.ok, rooms: names, members: members, info: info, pick: pick, messages: msgs)
        }.value
    }

    /// History for a specific room (used when the user switches rooms).
    private static func history(_ room: String) async -> [MeshMsg] {
        guard !room.isEmpty else { return [] }
        return await Task.detached {
            MeshClient.send(MeshRequest(cmd: "history", room: room, limit: 200)).messages ?? []
        }.value
    }
}

/// Device-local, per-room composer drafts. Drafts are intentionally not Broker
/// data: half-written text stays private to the Mac where it was typed.
private enum MeshRoomDraftCache {
    private static let defaultsKey = "pharos.mesh.roomDrafts.v1"

    static func draft(for room: String) -> String {
        guard !room.isEmpty else { return "" }
        return (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String])?[room] ?? ""
    }

    static func save(_ draft: String, for room: String) {
        guard !room.isEmpty else { return }
        var drafts = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if draft.isEmpty { drafts.removeValue(forKey: room) }
        else { drafts[room] = draft }
        UserDefaults.standard.set(drafts, forKey: defaultsKey)
    }
}
