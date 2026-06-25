import SwiftUI
import StoreKit

/// Entry point for online play: account → subscription paywall → lobby.
public struct InternetGameView: View {
    let brand: Brand
    @ObservedObject private var online = ChessOnline.shared
    @Environment(\.dismiss) private var dismiss

    public init(brand: Brand) { self.brand = brand }

    public var body: some View {
        NavigationStack {
            Group {
                if !online.isSignedIn {
                    AccountView(brand: brand)
                } else if !online.entitled {
                    PaywallView(brand: brand)
                } else {
                    OnlineLobbyView(brand: brand)
                }
            }
            .navigationTitle("Internet Game")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if online.isSignedIn {
                    ToolbarItem(placement: .primaryAction) { Button("Sign Out") { online.signOut() } }
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

/// Create or join an online game; share the invite code.
struct OnlineLobbyView: View {
    let brand: Brand
    @ObservedObject private var online = ChessOnline.shared
    @State private var created: ChessOnline.OnlineGame?
    @State private var joinCode = ""
    @State private var joined: (gameId: String, seat: Int)?
    @State private var minutes = 10

    var body: some View {
        Form {
            Section("Host a game") {
                Picker("Clock", selection: $minutes) { ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }
                Button {
                    Task { created = await online.createGame(variant: brand.onlineGameKey, base: minutes * 60, increment: 0) }
                } label: { Label("Create Game", systemImage: "plus.circle.fill") }
                if let g = created {
                    HStack { Text("Invite code"); Spacer()
                        Text(g.code).font(.title3.monospaced().bold()).foregroundStyle(brand.accent) }
                    ShareLink("Share invite", item: "Join my \(brand.title) game — invite code \(g.code)")
                    Text("Share the code. Friends join open seats; empty seats can be filled by the computer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Join a game") {
                TextField("Invite code", text: $joinCode).autocorrectionDisabled()
                Button {
                    Task { joined = await online.joinGame(code: joinCode.uppercased()) }
                } label: { Label("Join", systemImage: "arrow.right.circle.fill") }.disabled(joinCode.count < 6)
                if let j = joined { Label("Joined seat \(j.seat + 1) — waiting for the host to start.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let e = online.lastError { Section { Text(e).foregroundStyle(.red).font(.caption) } }
            Section { Text("Signed in as \(online.displayName ?? "you")").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
