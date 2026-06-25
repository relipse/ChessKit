import SwiftUI
import StoreKit

/// Entry point for online play: account → subscription paywall → lobby → live board.
public struct InternetGameView: View {
    let brand: Brand
    let variant: ChessVariant?
    let store: GameStore?
    @ObservedObject private var appearance: Appearance
    @ObservedObject private var online = ChessOnline.shared
    @Environment(\.dismiss) private var dismiss
    @State private var session: ChessOnline.OnlineSession?
    @State private var showAccount = false

    public init(brand: Brand, variant: ChessVariant? = nil, store: GameStore? = nil, appearance: Appearance = .shared) {
        self.brand = brand; self.variant = variant; self.store = store; self.appearance = appearance
    }

    public var body: some View {
        Group {
            if let session, let variant, let store {
                ChessGameView(variant: variant, brand: brand, appearance: appearance, store: store,
                              online: session, onExit: { self.session = nil })
            } else {
                NavigationStack {
                    Group {
                        if !online.isSignedIn { AccountView(brand: brand) }
                        else if !online.entitled { PaywallView(brand: brand) }
                        else { OnlineLobbyView(brand: brand, canPlay: variant != nil) { self.session = $0 } }
                    }
                    .navigationTitle("Internet Game")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                        if online.isSignedIn {
                            ToolbarItem(placement: .primaryAction) {
                                Menu { Button("Sign Out") { online.signOut() }
                                       Button("Delete Account", role: .destructive) { Task { await online.deleteAccount() } } }
                                label: { Image(systemName: "person.crop.circle") }
                            }
                        }
                    }
                }
            }
        }
        .tint(brand.accent)
        .task { await online.refreshEntitlement(); await online.loadProducts(brand.onlineProductIDs) }
    }
}

/// Register / sign in with name + email + password.
struct AccountView: View {
    let brand: Brand
    @ObservedObject private var online = ChessOnline.shared
    @State private var registering = true
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        Form {
            Picker("", selection: $registering) { Text("Create Account").tag(true); Text("Sign In").tag(false) }
                .pickerStyle(.segmented)
            Section {
                if registering { TextField("Name", text: $name) }
                TextField("Email", text: $email).autocorrectionDisabled()
                SecureField("Password", text: $password)
            } footer: {
                if let e = online.lastError { Text(e).foregroundStyle(.red) }
            }
            Section {
                Button {
                    Task { if registering { await online.register(name: name, email: email, password: password) }
                           else { await online.login(email: email, password: password) }
                           await online.refreshEntitlement() }
                } label: {
                    HStack { if online.busy { ProgressView() }; Text(registering ? "Create Account" : "Sign In").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent)
                .disabled(online.busy || email.isEmpty || password.count < 8 || (registering && name.isEmpty))
            }
            Section { Text("Online play needs an account so friends can invite you and your subscription follows you across all Kinsman chess apps.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Subscription paywall — StoreKit prices + terms + Restore (Apple-compliant).
struct PaywallView: View {
    let brand: Brand
    @ObservedObject private var online = ChessOnline.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "globe").font(.system(size: 48)).foregroundStyle(brand.accent)
                Text("Play Online").font(.title.bold())
                Text("Invite friends and play \(brand.title) over the internet. One **All-Access** subscription unlocks online play in every Kinsman chess app.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

                if online.products.isEmpty {
                    ProgressView().padding()
                } else {
                    ForEach(online.products, id: \.id) { p in
                        Button { Task { _ = await online.purchase(p) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.displayName).font(.headline)
                                    if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(p.displayPrice).font(.headline)
                                    if let unit = p.subscription?.subscriptionPeriod.unit { Text(periodLabel(unit)).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }.padding().frame(maxWidth: .infinity)
                            .background(p.id.contains(".all.") ? brand.accent.opacity(0.12) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }

                Button("Restore Purchases") { Task { await online.restore() } }.font(.subheadline)
                if let e = online.lastError { Text(e).font(.caption).foregroundStyle(.red) }

                Text("Auto-renewing subscription. Payment is charged to your Apple Account; it renews unless cancelled at least 24 hours before the period ends. Manage or cancel in Settings.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    Link("Terms", destination: URL(string: "https://kinsman.cc/chess/bughouse.html")!)
                    Link("Privacy", destination: URL(string: "https://kinsman.cc/chess/apps-privacy.html")!)
                }.font(.caption2)
            }.padding()
        }
    }

    private func periodLabel(_ u: Product.SubscriptionPeriod.Unit) -> String {
        switch u { case .day: return "daily"; case .week: return "weekly"; case .month: return "per month"
        case .year: return "per year"; @unknown default: return "" }
    }
}

/// Create or join an online game; share the invite code; launch the board when ready.
struct OnlineLobbyView: View {
    let brand: Brand
    let canPlay: Bool
    let onPlay: (ChessOnline.OnlineSession) -> Void
    @ObservedObject private var online = ChessOnline.shared
    @State private var created: ChessOnline.OnlineGame?
    @State private var joinCode = ""
    @State private var joinedGameId: String?
    @State private var minutes = 10
    @State private var opponentReady = false
    @State private var watch: Task<Void, Never>?

    var body: some View {
        Form {
            if !canPlay {
                Section { Label("Online play for this game is rolling out soon — your subscription already works in the other Kinsman chess apps.", systemImage: "clock").font(.callout) }
            }
            Section("Host a game") {
                Picker("Clock", selection: $minutes) { ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }
                Button {
                    Task {
                        created = await online.createGame(variant: brand.onlineGameKey, base: minutes * 60, increment: 0)
                        if let g = created { startWatch(host: true, gameId: g.id) }
                    }
                } label: { Label("Create Game", systemImage: "plus.circle.fill") }.disabled(!canPlay || created != nil)
                if let g = created {
                    HStack { Text("Invite code"); Spacer()
                        Text(g.code).font(.title3.monospaced().bold()).foregroundStyle(brand.accent) }
                    ShareLink("Share invite", item: "Join my \(brand.title) game — invite code \(g.code)")
                    if opponentReady {
                        Button { Task { await online.startGame(gameId: g.id); onPlay(.init(gameId: g.id, localColor: .white)) } }
                            label: { Label("Start Game", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Label("Waiting for an opponent to join…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Join a game") {
                TextField("Invite code", text: $joinCode).autocorrectionDisabled()
                Button {
                    Task { if let j = await online.joinGame(code: joinCode.uppercased()) {
                        joinedGameId = j.gameId; startWatch(host: false, gameId: j.gameId, myColor: j.seat == 0 ? .white : .black) } }
                } label: { Label("Join", systemImage: "arrow.right.circle.fill") }.disabled(joinCode.count < 6 || !canPlay)
                if joinedGameId != nil { Label("Joined — waiting for the host to start…", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let e = online.lastError { Section { Text(e).foregroundStyle(.red).font(.caption) } }
            Section { Text("Signed in as \(online.displayName ?? "you")").font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear { watch?.cancel() }
    }

    /// Host: watch for a second player to join. Guest: watch for the host to start, then launch.
    private func startWatch(host: Bool, gameId: String, myColor: PieceColor = .black) {
        watch?.cancel()
        watch = Task {
            while !Task.isCancelled {
                if let info = await online.gameInfo(gameId: gameId) {
                    if host, info.filled >= 2 { opponentReady = true }
                    if !host, info.status == "active" { onPlay(.init(gameId: gameId, localColor: myColor)); return }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}
