import SwiftUI

/// Reconstructs every board position of a saved game so it can be stepped through.
@MainActor
final class ReplayController: ObservableObject {
    let variant: ChessVariant
    let game: SavedGame
    let positions: [Position]
    let moveTargets: [(from: Int, to: Int)?]
    let sans: [String]
    @Published var ply = 0
    @Published var isPlaying = false
    private var task: Task<Void, Never>?

    init(variant: ChessVariant, game: SavedGame) {
        self.variant = variant
        self.game = game
        var pos = game.startPosition() ?? variant.startPosition()
        var allPos = [pos]
        var targets: [(from: Int, to: Int)?] = [nil]
        var sanList: [String] = []
        for move in game.moves {
            sanList.append(StandardRules.san(for: move, in: pos))
            pos = variant.make(move, in: pos)
            allPos.append(pos)
            targets.append(move.isDrop ? nil : (move.from, move.to))
        }
        self.positions = allPos
        self.moveTargets = targets
        self.sans = sanList
    }

    var current: Position { positions[min(ply, positions.count - 1)] }
    var lastMove: (from: Int, to: Int)? { moveTargets[min(ply, moveTargets.count - 1)] }
    var canForward: Bool { ply < positions.count - 1 }
    var canBack: Bool { ply > 0 }

    func start() { pause(); ply = 0 }
    func end() { pause(); ply = positions.count - 1 }
    func forward() { if canForward { ply += 1 } }
    func back() { if canBack { ply -= 1 } }
    func goTo(_ p: Int) { pause(); ply = max(0, min(p, positions.count - 1)) }

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        guard canForward else { return }
        isPlaying = true
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            while self.isPlaying && self.canForward {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled || !self.isPlaying { break }
                self.forward()
            }
            self.isPlaying = false
        }
    }
    func pause() { isPlaying = false; task?.cancel(); task = nil }
}

/// Step-through replay of a saved/finished game (works for every variant).
public struct ReplayView: View {
    @StateObject private var rc: ReplayController
    @ObservedObject private var appearance: Appearance
    let brand: Brand
    @Environment(\.dismiss) private var dismiss

    public init(variant: ChessVariant, game: SavedGame, brand: Brand, appearance: Appearance = .shared) {
        _rc = StateObject(wrappedValue: ReplayController(variant: variant, game: game))
        self.brand = brand
        self.appearance = appearance
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size = min(geo.size.width - 24, geo.size.height - 220)
                VStack(spacing: 14) {
                    BoardView(position: rc.current, flipped: rc.game.humanColor == .black,
                              lastMove: rc.lastMove, size: max(size, 240), appearance: appearance)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    moveStrip
                    transport
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            }
            .navigationTitle(rc.game.result ?? rc.game.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(brand.accent)
    }

    private var moveStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(rc.sans.enumerated()), id: \.offset) { i, san in
                        let isCurrent = rc.ply == i + 1
                        Text("\(i % 2 == 0 ? "\(i/2 + 1). " : "")\(san)")
                            .font(.caption.monospaced().weight(isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? brand.accent : .primary)
                            .id(i)
                            .onTapGesture { rc.goTo(i + 1) }
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            .frame(height: 36)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: rc.ply) { _, p in withAnimation { proxy.scrollTo(max(0, p - 1), anchor: .center) } }
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            button("backward.end.fill") { rc.start() }.disabled(!rc.canBack)
            button("backward.fill") { rc.back() }.disabled(!rc.canBack)
            button(rc.isPlaying ? "pause.circle.fill" : "play.circle.fill", big: true) { rc.togglePlay() }
            button("forward.fill") { rc.forward() }.disabled(!rc.canForward)
            button("forward.end.fill") { rc.end() }.disabled(!rc.canForward)
        }
        .padding(.vertical, 6)
    }

    private func button(_ name: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(big ? .largeTitle : .title2).foregroundStyle(brand.accent)
        }
    }
}

/// Lists played games (newest first) for replay, with delete.
struct GameHistoryListView: View {
    let variant: ChessVariant
    let brand: Brand
    @ObservedObject var store: GameStore
    @ObservedObject var appearance: Appearance
    @Environment(\.dismiss) private var dismiss
    @State private var replaying: SavedGame?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.history) { game in
                    Button { replaying = game } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(game.result ?? game.name).font(.headline).foregroundStyle(.primary)
                            Text("\(game.plyCount) moves · \(game.difficulty.title) · \(game.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.history[$0] }.forEach(store.deleteHistory) }
                if store.history.isEmpty {
                    Text("Games you play will be saved here to replay.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Game History")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $replaying) { game in
                ReplayView(variant: variant, game: game, brand: brand, appearance: appearance)
            }
        }
        .tint(brand.accent)
    }
}
