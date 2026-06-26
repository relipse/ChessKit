import SwiftUI

/// One app in the Kinsman Software chess family, for cross-promotion.
public struct ChessAppEntry: Identifiable, Sendable {
    public let id: String          // App Store numeric ID
    public let title: String       // "Atomic Chess"
    public let blurb: String
    public let systemImage: String
    public let accent: Color
    public var appStoreURL: URL { URL(string: "https://apps.apple.com/app/id\(id)")! }
}

/// The full family of variant chess apps by Kinsman Software LLC. Used by the in-app
/// "More Chess Games" screen so players can discover and jump to the others.
public enum ChessAppCatalog {
    public static let developerName = "Kinsman Software LLC"
    /// App Store search for everything by the studio (works before/after individual apps go live).
    public static let developerURL = URL(string: "https://apps.apple.com/search?term=Kinsman%20Software%20chess")!

    public static let apps: [ChessAppEntry] = [
        ChessAppEntry(id: "6784078356", title: "Fog of War Chess (Kriegspiel)",
                      blurb: "Fog of war — you see only your own pieces.",
                      systemImage: "eye.slash.fill", accent: Color(red: 0.149, green: 0.196, blue: 0.376)),
        ChessAppEntry(id: "6784077125", title: "Crazyhouse Chess",
                      blurb: "Capture pieces and drop them back into play.",
                      systemImage: "shippingbox.fill", accent: Color(red: 0.839, green: 0.431, blue: 0.157)),
        ChessAppEntry(id: "6784077236", title: "Atomic Chess",
                      blurb: "Captures explode — blow up the enemy king.",
                      systemImage: "atom", accent: Color(red: 0.157, green: 0.627, blue: 0.431)),
        ChessAppEntry(id: "6784078275", title: "Fischer Random Chess",
                      blurb: "Chess960 — 960 shuffled starting setups.",
                      systemImage: "shuffle", accent: Color(red: 0.376, green: 0.251, blue: 0.588)),
        ChessAppEntry(id: "6784077912", title: "Losers Chess",
                      blurb: "Get checkmated to win; captures are forced.",
                      systemImage: "flag.checkered", accent: Color(red: 0.588, green: 0.157, blue: 0.235)),
        ChessAppEntry(id: "6784079152", title: "Shapeshifter Chess",
                      blurb: "Pieces move by the file they stand on.",
                      systemImage: "wand.and.stars", accent: Color(red: 0.275, green: 0.471, blue: 0.588)),
        ChessAppEntry(id: "6784103827", title: "Pawn Duel",
                      blurb: "King and three pawns in opposite corners.",
                      systemImage: "flag.2.crossed.fill", accent: Color(red: 0.55, green: 0.36, blue: 0.20)),
        ChessAppEntry(id: "6784272381", title: "Bughouse Chess",
                      blurb: "4-player team chess — capture and pass to your partner.",
                      systemImage: "person.2.square.stack", accent: Color(red: 0.149, green: 0.569, blue: 0.549)),
        ChessAppEntry(id: "6784103760", title: "Chess by Kinsman Software",
                      blurb: "Clean, classic chess vs the computer or a friend.",
                      systemImage: "crown.fill", accent: Color(red: 0.55, green: 0.36, blue: 0.20)),
        // App Store ID is a placeholder until the App Store Connect record is created.
        ChessAppEntry(id: "6784999999", title: "My Turn Chess",
                      blurb: "Real-time chess — no turns; both players move at once.",
                      systemImage: "bolt.fill", accent: Color(red: 0.86, green: 0.27, blue: 0.42))
    ]
}

/// A cross-promotion screen advertising the rest of the chess family.
public struct MoreGamesView: View {
    /// The current app's App Store ID, so it's excluded from the list.
    let currentAppStoreID: String?
    let brand: Brand
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(currentAppStoreID: String?, brand: Brand) {
        self.currentAppStoreID = currentAppStoreID
        self.brand = brand
    }

    private var others: [ChessAppEntry] {
        ChessAppCatalog.apps.filter { $0.id != currentAppStoreID }
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(others) { app in
                        Button { openURL(app.appStoreURL) } label: { row(app) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("More chess by \(ChessAppCatalog.developerName)").textCase(nil)
                } footer: {
                    Text("Each is a different chess variant vs the computer — same clean board, brand-new rules.")
                }
                Section {
                    Button {
                        openURL(ChessAppCatalog.developerURL)
                    } label: {
                        Label("See all apps by \(ChessAppCatalog.developerName)", systemImage: "apps.iphone")
                            .font(.headline)
                    }
                }
            }
            .navigationTitle("More Chess Games")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }

    private func row(_ app: ChessAppEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: app.systemImage)
                .font(.title2.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Theme.heroGradient(app.accent), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.title).font(.headline).foregroundStyle(.primary)
                Text(app.blurb).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.forward.app.fill").foregroundStyle(app.accent)
        }
        .padding(.vertical, 4)
    }
}
