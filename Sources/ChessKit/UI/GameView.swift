import SwiftUI

/// A complete, self-contained "play the computer" screen for any variant. Each app's
/// root is essentially `ChessGameView(variant: …, brand: …)`.
public struct ChessGameView: View {
    @StateObject private var game: GameController
    @ObservedObject private var appearance: Appearance
    private let brand: Brand
    private let onExit: (() -> Void)?

    @State private var showSettings = false
    @State private var showNewGame = false
    @State private var showSave = false
    @State private var showMore = false
    @State private var saveName = ""
    /// Nearby transport (only set in `.nearby` mode); wired to the controller on appear.
    private let nearby: NearbyService?

    /// Simple init (no menu/persistence) — handy for previews/embedding.
    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared, suite: String? = nil) {
        _game = StateObject(wrappedValue: GameController(variant: variant, suite: suite))
        self.appearance = appearance
        self.brand = brand
        self.onExit = nil
        self.nearby = nil
    }

    /// Full init used by `ChessRootView`: launches a fresh or restored game and can
    /// return to the main menu via `onExit`.
    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared,
                suite: String? = nil, store: GameStore, launch: GameLaunch,
                onExit: (() -> Void)? = nil) {
        let controller: GameController
        switch launch {
        case .fresh(let mode, let color, let diff, let start):
            controller = GameController(variant: variant, humanColor: color, difficulty: diff,
                                        suite: suite, store: store, leaderboardID: brand.leaderboardID,
                                        mode: mode, startOverride: start)
        case .restore(let saved):
            controller = GameController(variant: variant, suite: suite, store: store, restore: saved,
                                        leaderboardID: brand.leaderboardID)
        }
        _game = StateObject(wrappedValue: controller)
        self.appearance = appearance
        self.brand = brand
        self.onExit = onExit
        self.nearby = nil
    }

    /// Nearby (two-device) game. The transport must already be connected (`nearby.ready`).
    public init(variant: ChessVariant, brand: Brand, appearance: Appearance = .shared,
                suite: String? = nil, store: GameStore, nearby service: NearbyService,
                onExit: (() -> Void)? = nil) {
        _game = StateObject(wrappedValue: GameController(variant: variant, suite: suite, store: store,
                                                         mode: .nearby, localColor: service.localColor))
        self.appearance = appearance
        self.brand = brand
        self.onExit = onExit
        self.nearby = service
    }

    public var body: some View {
        GeometryReader { geo in
            let boardSize = min(geo.size.width - 24, geo.size.height - 280)
            VStack(spacing: 12) {
                header
                statusBar
                if game.variant.usesPockets {
                    PocketView(pocket: game.position.pockets[topColor] ?? Pocket(),
                               color: topColor, interactive: false, accent: brand.accent,
                               appearance: appearance)
                }
                boardStack(size: max(boardSize, 240))
                if game.variant.usesPockets {
                    PocketView(pocket: game.position.pockets[bottomColor] ?? Pocket(),
                               color: bottomColor, selected: game.pocketSelection,
                               interactive: game.isHumanTurn, accent: brand.accent, appearance: appearance,
                               onSelect: { game.selectPocket($0) })
                }
                rulesSummary
                infoPanel
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
        }
        .overlay { if game.pendingPromotion != nil { promotionOverlay } }
        .overlay { if game.status.isOver { gameOverOverlay } }
        .sheet(isPresented: $showSettings) { SettingsView(game: game, brand: brand, appearance: appearance) }
        .sheet(isPresented: $showNewGame) { NewGameSheet(game: game, brand: brand) }
        .alert("Save Game", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Save") { game.saveSlot(name: saveName.isEmpty ? game.defaultSaveName() : saveName) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Save this game so you can resume it later.") }
        .sheet(isPresented: $showMore) { MoreGamesView(currentAppStoreID: brand.appStoreID, brand: brand) }
        .tint(brand.accent)
        .onAppear {
            if game.mode == .computer, game.humanColor == .black { game.startIfAIOpens() }
            if let nearby {
                game.localColor = nearby.localColor
                game.onLocalMove = { move in nearby.send(move) }
                nearby.onReceiveMove = { [weak game] move in game?.applyRemoteMove(move) }
            }
        }
    }

    // MARK: Pieces of the screen

    private var header: some View {
        HStack(spacing: 10) {
            if let onExit {
                Button { game.recordToHistory(); onExit() } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                }
            }
            Image(systemName: brand.systemImage)
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.heroGradient(brand.accent), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 0) {
                Text(brand.title).font(.title3.weight(.bold).width(.condensed))
                Text(headerSubtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if game.mode != .nearby {
                Button { saveName = game.defaultSaveName(); showSave = true } label: {
                    Image(systemName: "square.and.arrow.down").font(.title3)
                }.disabled(game.history.isEmpty)
                Button { showNewGame = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
        }
        .padding(.top, 6)
    }

    private var headerSubtitle: String {
        switch game.mode {
        case .computer: return "vs Computer · \(game.difficulty.title)"
        case .passAndPlay: return "2 Players · this device"
        case .nearby: return "Nearby · you play \(game.localColor == .white ? "White" : "Black")"
        }
    }

    private var statusBar: some View {
        HStack {
            if game.status.isOver {
                PillBadge(endLabel, color: endColor)
            } else if game.thinking {
                PillBadge("● THINKING", color: brand.accent, pulsing: true)
            } else {
                PillBadge(game.turnLabel, color: game.isHumanTurn ? .green : .gray)
            }
            if game.lastVerdictIllegal {
                PillBadge("ILLEGAL — TRY AGAIN", color: .red, filled: false)
            }
            Spacer()
            if game.mode == .nearby, let name = nearby?.peerName {
                Label(name, systemImage: "wifi").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(height: 24)
    }

    private var endLabel: String {
        if game.mode == .computer { return game.humanWon ? "YOU WIN" : (game.status.winner == nil ? "DRAW" : "YOU LOSE") }
        return game.status.winner == nil ? "DRAW" : "\(game.status.winner == .white ? "WHITE" : "BLACK") WINS"
    }
    private var endColor: Color {
        if game.status.winner == nil { return .gray }
        if game.mode == .computer { return game.humanWon ? .green : .red }
        return brand.accent
    }

    private func boardStack(size: CGFloat) -> some View {
        BoardView(position: game.position,
                  flipped: game.flipped,
                  lastMove: game.lastMove,
                  selected: game.selected,
                  targets: game.targets,
                  checkSquare: game.checkSquare,
                  hiddenColor: game.fogColor,
                  size: size, appearance: appearance,
                  onTap: { game.tap($0) },
                  onMove: { from, to in game.move(from: from, to: to) },
                  onDropPiece: { kind, sq in game.drop(kind, to: sq) })
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    /// The colour shown along the bottom edge (the local perspective), and its opposite.
    private var bottomColor: PieceColor { game.flipped ? .black : .white }
    private var topColor: PieceColor { game.flipped ? .white : .black }

    /// A one-line rules reminder under the board, plus a link to the other chess apps.
    private var rulesSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(brand.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.variant.blurb).font(.caption).foregroundStyle(.secondary)
                Button { showMore = true } label: {
                    Label("More games like this — support the developer", systemImage: "square.grid.2x2.fill")
                        .font(.caption2.weight(.semibold)).foregroundStyle(brand.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var infoPanel: some View {
        if game.fogColor != nil {
            umpireLog
        } else {
            moveList
        }
    }

    private var umpireLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if game.umpireLog.isEmpty {
                        Text("The umpire's calls will appear here. You can only see your own pieces.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(game.umpireLog.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.caption.monospaced()).id(i)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 120)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: game.umpireLog.count) { _, c in withAnimation { proxy.scrollTo(c - 1, anchor: .bottom) } }
        }
    }

    private var moveList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(stride(from: 0, to: game.sanHistory.count, by: 2)), id: \.self) { i in
                    let n = i / 2 + 1
                    Text("\(n).").font(.caption2).foregroundStyle(.secondary)
                    Text(game.sanHistory[i]).font(.caption.monospaced().weight(.semibold))
                    if i + 1 < game.sanHistory.count {
                        Text(game.sanHistory[i + 1]).font(.caption.monospaced())
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(height: 36)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var promotionOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { game.cancelPromotion() }
            VStack(spacing: 12) {
                Text("Promote to").font(.headline)
                HStack(spacing: 14) {
                    ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                        Button { game.choosePromotion(kind) } label: {
                            PieceGlyph(piece: Piece(color: game.humanColor, kind: kind), size: 52,
                                       appearance: appearance)
                                .frame(width: 60, height: 60)
                                .background(brand.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var gameOverOverlay: some View {
        VStack(spacing: 10) {
            Spacer()
            VStack(spacing: 12) {
                Text(game.status.winner == nil ? "🤝" : (game.mode == .computer ? (game.humanWon ? "🏆" : "💥") : "🏆"))
                    .font(.system(size: 44))
                Text(game.resultText).font(.headline).multilineTextAlignment(.center)
                Button { showNewGame = true } label: {
                    Text("New Game").font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .background(brand.accent, in: Capsule())
                }
            }
            .padding(26).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .padding(.bottom, 40)
        }
        .transition(.opacity)
    }
}
