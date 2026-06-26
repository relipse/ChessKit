import SwiftUI
import StoreKit

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

    @ViewBuilder func gameCover<Content: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

/// A connected nearby session, lifted to the menu root so the board can be presented
/// full-screen (not nested inside the lobby sheet).
struct NearbyLaunch: Identifiable {
    let id = UUID()
    let service: NearbyService
}

/// A live internet session, lifted to the menu root so the board is full-screen.
struct OnlineLaunch: Identifiable {
    let id = UUID()
    let session: ChessOnline.OnlineSession
}

/// How a game should be launched from the menu.
public enum GameLaunch: Identifiable {
    case fresh(mode: GameMode, humanColor: PieceColor, difficulty: Difficulty, start: Position? = nil)
    case restore(SavedGame)
    public var id: String {
        switch self {
        case .fresh(let m, let c, let d, let s): return "fresh-\(m.rawValue)-\(c)-\(d.level)-\(s?.fen() ?? "")"
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
        if UserDefaults.standard.string(forKey: "shot") == "game" {
            // App Store screenshot mode: boot straight into a lively mid-game board.
            ChessGameView(variant: variant, brand: brand, appearance: appearance, suite: suite,
                          store: store, launch: .restore(DemoGame.savedGame(for: variant)))
                .tint(brand.accent)
        } else {
            SplashGate(brand: brand) {
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
    @State private var showHistory = false
    @State private var showAbout = false
    @State private var showMore = false
    @State private var showNearby = false
    @State private var nearbyLaunch: NearbyLaunch?
    @State private var pendingNearby: NearbyService?
    @State private var showOnline = false
    @State private var onlineLaunch: OnlineLaunch?
    @State private var pendingOnline: ChessOnline.OnlineSession?
    @State private var showSetup = false
    @State private var showPieceSetup = false
    @Environment(\.requestReview) private var requestReview
    @AppStorage("ck.launchCount") private var launchCount = 0
    @AppStorage("ck.didPromptReview") private var didPromptReview = false

    // Saves are only ever offered for *this* app's variant — you can't continue or load a
    // game of a different variant (guards against any stray/cross-variant entry in the store).
    private var resumableAutosave: SavedGame? {
        guard let a = store.autosave, a.variantName == variant.name else { return nil }
        return a
    }
    private var variantSlots: [SavedGame] { store.slots.filter { $0.variantName == variant.name } }
    private var variantHistory: [SavedGame] { store.history.filter { $0.variantName == variant.name } }

    public var body: some View {
        ZStack {
            VStack(spacing: 18) {
                Spacer()
                hero
                Spacer()
                VStack(spacing: 12) {
                    if let auto = resumableAutosave {
                        menuButton("Continue", systemImage: "play.fill", prominent: true) {
                            onLaunch(.restore(auto))
                        }
                        Text("\(auto.variantName) · \(auto.plyCount) moves")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    menuButton("New Game", systemImage: "plus.circle.fill",
                               prominent: resumableAutosave == nil) { showNewGame = true }
                    if variant is Chess960 {
                        menuButton("Set Up Position", systemImage: "slider.horizontal.below.square.filled.and.square") { showSetup = true }
                    }
                    if variant is StandardChess {
                        menuButton("Set Up Pieces", systemImage: "square.grid.3x3.square") { showPieceSetup = true }
                    }
                    menuButton("Play Nearby", systemImage: "wifi") { showNearby = true }
                    if brand.onlineSlug != nil {
                        menuButton("Internet Game", systemImage: "globe") { showOnline = true }
                    }
                    if !variantSlots.isEmpty {
                        menuButton("Load Game", systemImage: "tray.full.fill") { showLoad = true }
                    }
                    if !variantHistory.isEmpty {
                        menuButton("Game History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    }
                    menuButton("Leaderboard", systemImage: "trophy.fill") {
                        GameCenter.shared.showDashboard(leaderboardID: brand.leaderboardID)
                    }
                    menuButton("How to Play", systemImage: "book.fill") { showRules = true }
                    menuButton("Appearance", systemImage: "paintpalette.fill") { showAppearance = true }
                    HStack(spacing: 12) {
                        ShareLink(item: brand.appStoreURL, message: Text(brand.shareMessage)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        compactButton("Rate", systemImage: "star.fill") { requestReview() }
                        compactButton("About", systemImage: "info.circle.fill") { showAbout = true }
                    }
                    menuButton("More Chess Games", systemImage: "square.grid.2x2.fill") { showMore = true }   // always last
                }
                .frame(maxWidth: 420)
                Spacer()
                VStack(spacing: 2) {
                    Text("vs Computer · Offline · Kinsman Software LLC")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(MainMenuView.appVersion).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)            // keep the button column readable on big screens…
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // …but fill the whole window (iPad/Mac)
        // Background via a modifier so the (fill-scaled) art never drives layout size — otherwise
        // on wide windows (Mac/iPad) it balloons and pushes the menu off-screen.
        .background {
            if let bg = brand.backgroundAsset {
                ZStack {
                    Image(bg, bundle: .main).resizable().scaledToFill()
                    Color.black.opacity(0.35)
                }
                .clipped()
                .ignoresSafeArea()
            } else {
                Theme.heroGradient(brand.accent).opacity(0.12).ignoresSafeArea()
            }
        }
        .onAppear {
            trackLaunchAndMaybePrompt()
            GameCenter.shared.authenticate()
        }
        .sheet(isPresented: $showNewGame) {
            NewGameOptionsView(variant: variant, brand: brand, appearance: appearance) { mode, color, diff in
                showNewGame = false
                onLaunch(.fresh(mode: mode, humanColor: color, difficulty: diff))
            }
        }
        // Lobby → on connect, dismiss the sheet, THEN (onDismiss) present the board full-screen.
        // (iOS won't present a fullScreenCover while the sheet is still up — that left it stuck
        // at "Connected! Starting…".)
        .sheet(isPresented: $showNearby, onDismiss: {
            if let s = pendingNearby { pendingNearby = nil; nearbyLaunch = NearbyLaunch(service: s) }
        }) {
            NearbyLobbyView(variant: variant, brand: brand, appearance: appearance, store: store,
                            onConnected: { service in pendingNearby = service; showNearby = false })
        }
        .gameCover(item: $nearbyLaunch) { launch in
            ChessGameView(variant: variant, brand: brand, appearance: appearance, suite: nil,
                          store: store, nearby: launch.service,
                          onExit: { launch.service.stop(); nearbyLaunch = nil })
        }
        .sheet(isPresented: $showOnline, onDismiss: {
            if let s = pendingOnline { pendingOnline = nil; onlineLaunch = OnlineLaunch(session: s) }
        }) {
            InternetGameView(brand: brand, variant: variant, store: store, appearance: appearance,
                             onPlay: { session in pendingOnline = session; showOnline = false })
        }
        .gameCover(item: $onlineLaunch) { launch in
            ChessGameView(variant: variant, brand: brand, appearance: appearance, suite: nil,
                          store: store, online: launch.session,
                          onExit: { onlineLaunch = nil; showOnline = false })
        }
        .sheet(isPresented: $showSetup) {
            Chess960SetupView(brand: brand, store: store, appearance: appearance) { pos, mode in
                onLaunch(.fresh(mode: mode, humanColor: .white, difficulty: .medium, start: pos))
            }
        }
        .sheet(isPresented: $showPieceSetup) {
            PositionSetupView(brand: brand, appearance: appearance) { pos, mode in
                onLaunch(.fresh(mode: mode, humanColor: pos.sideToMove, difficulty: .medium, start: pos))
            }
        }
        .sheet(isPresented: $showLoad) {
            SavedGamesListView(variant: variant, brand: brand, store: store) { onLaunch(.restore($0)) }
        }
        .sheet(isPresented: $showRules) { RulesView(variant: variant, brand: brand) }
        .sheet(isPresented: $showAppearance) { AppearanceSettingsView(brand: brand, appearance: appearance) }
        .sheet(isPresented: $showHistory) {
            GameHistoryListView(variant: variant, brand: brand, store: store, appearance: appearance)
        }
        .sheet(isPresented: $showAbout) { AboutView(brand: brand) }
        .sheet(isPresented: $showMore) {
            MoreGamesView(currentAppStoreID: brand.appStoreID, brand: brand)
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Group {
                if let logo = brand.logoAsset {
                    Image(logo, bundle: .main).resizable().scaledToFit()
                        .frame(width: 116, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 26))
                } else {
                    Image(systemName: brand.systemImage)
                        .font(.system(size: 56, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 116, height: 116)
                        .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 26))
                }
            }
            .shadow(color: brand.accent.opacity(0.4), radius: 12, y: 6)
            Text(brand.displayTitle)
                .font(.system(.largeTitle, design: .rounded).weight(.heavy))
                .multilineTextAlignment(.center)
            Text(variant.blurb)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 12)
        }
    }

    /// App version + build from the bundle, shown at the bottom of the menu.
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    /// Count launches; on the 10th, ask the system to show the rating prompt once.
    private func trackLaunchAndMaybePrompt() {
        launchCount += 1
        if launchCount >= 10 && !didPromptReview {
            didPromptReview = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { requestReview() }
        }
    }

    private func compactButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

/// Pick mode + side + difficulty for a new game.
struct NewGameOptionsView: View {
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var appearance: Appearance
    let onStart: (GameMode, PieceColor, Difficulty) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: GameMode = .computer
    @State private var color: PieceColor = .white
    @State private var difficulty: Difficulty = .medium

    /// Real-time variants (My Turn Chess) play every mode without a turn lock.
    private var realtime: Bool { variant.isRealtime }

    var body: some View {
        NavigationStack {
            Form {
                Section("Opponent") {
                    Picker("Mode", selection: $mode) {
                        Text("Computer").tag(GameMode.computer)
                        Text("2 Players").tag(GameMode.passAndPlay)
                        Text("Watch").tag(GameMode.watch)
                    }.pickerStyle(.segmented)
                    if realtime, mode == .computer {
                        Text("Real-time — you and the computer move at once; the computer is throttled by the difficulty below (higher = faster + stronger).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if realtime, mode == .passAndPlay {
                        Text("Real-time — both players share this device; grab any piece of either colour and move whenever you like.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if mode == .passAndPlay {
                        Text("Two players take turns on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if mode == .watch {
                        Text(realtime ? "Watch two throttled computers scramble in real time."
                                      : "Sit back and watch the computer play itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if mode == .computer {
                    Section("Play as") {
                        Picker("Side", selection: $color) {
                            Text("White").tag(PieceColor.white)
                            Text("Black").tag(PieceColor.black)
                        }.pickerStyle(.segmented)
                    }
                }
                if mode == .computer || mode == .watch {
                    Section(realtime ? "Computer Speed & Strength" : (mode == .watch ? "Strength" : "Difficulty")) {
                        DifficultyPicker(difficulty: $difficulty)
                    }
                }
                if realtime { Section("Checks") { MyTurnRulePicker() } }
                Section {
                    Button { onStart(mode, color, difficulty); dismiss() } label: {
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
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var store: GameStore
    let onLoad: (SavedGame) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Only this app's variant — never offer to load a different variant's game.
    private var slots: [SavedGame] { store.slots.filter { $0.variantName == variant.name } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(slots) { game in
                    Button { onLoad(game); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(game.name).font(.headline).foregroundStyle(.primary)
                            Text("\(game.plyCount) moves · \(game.difficulty.title) · \(game.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { slots[$0] }.forEach(store.delete) }
                if slots.isEmpty {
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
        case "Losers":
            return ["The goal is inverted — you WIN by getting checkmated.",
                    "You ALSO win if you lose all your pieces (only your king left).",
                    "If you can capture, you must — so force your opponent to take your army.",
                    "A backwards race: shed your pieces faster than your opponent does."]
        case "Shapeshifter":
            return ["Every non-pawn piece moves by the FILE it stands on, and its powers change as it moves.",
                    "a/h files move like rooks, b/g like knights, c/f like bishops.",
                    "d-file pieces move like a queen; e-file like a king (one step).",
                    "Pawns are normal. Checkmate the king to win."]
        case "My Turn Chess":
            return ["Real-time chess — there are NO turns. Both armies are live at once.",
                    "Play vs the Computer, 2 players on one device, or against someone Nearby/over the Internet.",
                    "Grab a piece of your colour and move it; the first legal move registers instantly — no waiting.",
                    "vs Computer: you both move at once. The difficulty level throttles the computer (higher = faster + stronger) so it doesn't blitz you.",
                    "Checks are up to you (Settings): 'King Capture' ignores check — just grab the enemy king; 'Checkmate' plays orthodox — no moving into check, mate or stalemate ends it.",
                    "My Turn Chess Variant by Jim K and Diana L in ~1998."]
        case "Pawn Duel":
            return ["Each side starts with just a king and three pawns in opposite corners.",
                    "Ordinary chess rules apply.",
                    "Race a pawn to the far side to promote, then hunt the enemy king.",
                    "Checkmate to win."]
        default:
            return ["Standard chess — move your pieces to checkmate the enemy king.",
                    "Each piece moves its own way; pawns promote on the last rank.",
                    "Castle, capture en passant, and avoid stalemate.",
                    "Beat the computer across 10 difficulty levels."]
        }
    }
}
