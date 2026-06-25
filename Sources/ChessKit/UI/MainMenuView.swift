import SwiftUI

extension View {
    /// Present the game full-screen on iOS / Catalyst, as a sheet on plain macOS.
    @ViewBuilder func gameCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

/// How a game should be launched from the menu.
public enum GameLaunch: Identifiable {
    case fresh(humanColor: PieceColor, difficulty: Difficulty)
    case restore(SavedGame)
    public var id: String {
        switch self {
        case .fresh(let c, let d): return "fresh-\(c)-\(d.rawValue)"
        case .restore(let g): return "restore-\(g.id)"
        }
    }
}

/// The app root: a main menu that launches into a full-screen game. Every variant app
/// uses this, so they all look and behave identically apart from the chess rules.
public struct ChessRootView: View {
    let variant: ChessVariant
    let brand: Brand
    let suite: String?

    @StateObject private var store = GameStore()
    @StateObject private var appearance: Appearance
    @State private var launch: GameLaunch?

    public init(variant: ChessVariant, brand: Brand, suite: String? = nil) {
        self.variant = variant
        self.brand = brand
        self.suite = suite
        _appearance = StateObject(wrappedValue: Appearance(suite: suite))
    }

    public var body: some View {
        MainMenuView(variant: variant, brand: brand, store: store, appearance: appearance,
                     onLaunch: { launch = $0 })
            .gameCover(item: $launch) { l in
                ChessGameView(variant: variant, brand: brand, appearance: appearance,
                              suite: suite, store: store, launch: l,
                              onExit: { launch = nil })
            }
            .tint(brand.accent)
    }
}

public struct MainMenuView: View {
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var store: GameStore
    @ObservedObject var appearance: Appearance
    let onLaunch: (GameLaunch) -> Void

    @State private var showNewGame = false
    @State private var showLoad = false
    @State private var showRules = false
    @State private var showAppearance = false

    public var body: some View {
        ZStack {
            Theme.heroGradient(brand.accent).opacity(0.12).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                hero
                Spacer()
                VStack(spacing: 12) {
                    if let auto = store.autosave {
                        menuButton("Continue", systemImage: "play.fill", prominent: true) {
                            onLaunch(.restore(auto))
                        }
                        Text("\(auto.variantName) · \(auto.plyCount) moves")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    menuButton("New Game", systemImage: "plus.circle.fill",
                               prominent: store.autosave == nil) { showNewGame = true }
                    if !store.slots.isEmpty {
                        menuButton("Load Game", systemImage: "tray.full.fill") { showLoad = true }
                    }
                    menuButton("How to Play", systemImage: "book.fill") { showRules = true }
                    menuButton("Appearance", systemImage: "paintpalette.fill") { showAppearance = true }
                }
                .frame(maxWidth: 420)
                Spacer()
                Text("vs Computer · Offline").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showNewGame) {
            NewGameOptionsView(variant: variant, brand: brand, appearance: appearance) { color, diff in
                showNewGame = false
                onLaunch(.fresh(humanColor: color, difficulty: diff))
            }
        }
        .sheet(isPresented: $showLoad) {
            SavedGamesListView(brand: brand, store: store) { onLaunch(.restore($0)) }
        }
        .sheet(isPresented: $showRules) { RulesView(variant: variant, brand: brand) }
        .sheet(isPresented: $showAppearance) { AppearanceSettingsView(brand: brand, appearance: appearance) }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: brand.systemImage)
                .font(.system(size: 56, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 116, height: 116)
                .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 26))
                .shadow(color: brand.accent.opacity(0.4), radius: 12, y: 6)
            Text("\(brand.title) Chess")
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                .multilineTextAlignment(.center)
            Text(variant.blurb)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func menuButton(_ title: String, systemImage: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(prominent ? AnyShapeStyle(brand.accent) : AnyShapeStyle(.thinMaterial),
                            in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(prominent ? .white : Color.primary)
        }
    }
}

/// Pick side + difficulty for a new game.
struct NewGameOptionsView: View {
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var appearance: Appearance
    let onStart: (PieceColor, Difficulty) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var color: PieceColor = .white
    @State private var difficulty: Difficulty = .medium

    var body: some View {
        NavigationStack {
            Form {
                Section("Play as") {
                    Picker("Side", selection: $color) {
                        Text("White").tag(PieceColor.white)
                        Text("Black").tag(PieceColor.black)
                    }.pickerStyle(.segmented)
                }
                Section("Difficulty") {
                    Picker("Strength", selection: $difficulty) {
                        ForEach(Difficulty.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section {
                    Button { onStart(color, difficulty); dismiss() } label: {
                        Text("Start").frame(maxWidth: .infinity).font(.headline)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("New \(brand.title) Game")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}

/// List saved games with load + delete.
struct SavedGamesListView: View {
    let brand: Brand
    @ObservedObject var store: GameStore
    let onLoad: (SavedGame) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.slots) { game in
                    Button { onLoad(game); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(game.name).font(.headline).foregroundStyle(.primary)
                            Text("\(game.plyCount) moves · \(game.difficulty.title) · \(game.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.slots[$0] }.forEach(store.delete) }
                if store.slots.isEmpty {
                    Text("No saved games yet.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Saved Games")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }
}

/// Rules / how-to-play for the variant.
struct RulesView: View {
    let variant: ChessVariant
    let brand: Brand
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(variant.blurb).font(.title3.weight(.semibold))
                    ForEach(rules, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                    }
                    Divider()
                    Label("Move by dragging a piece, or tap a piece then tap its destination.",
                          systemImage: "hand.draw.fill").font(.callout)
                    Label("Save from the in-game menu; resume later with Continue or Load Game.",
                          systemImage: "tray.and.arrow.down.fill").font(.callout)
                }
                .padding(20)
            }
            .navigationTitle("How to Play \(brand.title)")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }

    private var rules: [String] {
        switch variant.name {
        case "Kriegspiel":
            return ["You see only your own pieces — the enemy army is hidden.",
                    "Try a move; the umpire says if it's illegal (free retry).",
                    "The umpire announces captures, checks (and direction) and your pawn-try count.",
                    "Checkmate the hidden king to win."]
        case "Crazyhouse":
            return ["Capture an enemy piece and it joins your reserve.",
                    "On your turn you may drop a reserve piece onto any empty square instead of moving.",
                    "Pawns can't be dropped on the 1st or 8th rank.",
                    "A promoted pawn reverts to a pawn when captured."]
        case "Atomic":
            return ["Every capture explodes: the captured piece, the capturer, and all adjacent non-pawns vanish.",
                    "Win by exploding the enemy king.",
                    "Kings can never capture, and you may not blow up your own king.",
                    "You can be in check and still win by detonating the enemy king."]
        case "Fischer Random":
            return ["The back rank is shuffled into one of 960 setups (bishops opposite colours, king between rooks).",
                    "Both sides start with the same shuffled position.",
                    "Castling still lands the king on g/c and rook on f/d.",
                    "Otherwise it's completely standard chess."]
        default:
            return ["Standard chess rules. Checkmate the king to win."]
        }
    }
}
