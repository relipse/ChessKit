import Foundation

/// A serialisable snapshot of a game: the starting position plus the move list.
/// Replaying the moves through the variant reconstructs the exact current state,
/// so this works for every variant (including Crazyhouse pockets and Chess960).
public struct SavedGame: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var date: Date
    public var variantName: String
    public var startFEN: String
    public var rookFiles: [String: Int]   // Chess960 castling rook files ("K","Q","k","q")
    public var moves: [Move]
    public var humanColor: PieceColor
    public var difficulty: Difficulty
    /// Final result text, set when a game is recorded into history ("" if still in progress).
    public var result: String?
    /// How the game was played (defaults to vs-computer for older saves).
    public var mode: GameMode?
    /// Move count, for menu display ("12 moves").
    public var plyCount: Int { moves.count }

    public init(id: UUID = UUID(), name: String, date: Date, variantName: String,
                startFEN: String, rookFiles: [String: Int], moves: [Move],
                humanColor: PieceColor, difficulty: Difficulty, result: String? = nil,
                mode: GameMode? = nil) {
        self.id = id; self.name = name; self.date = date; self.variantName = variantName
        self.startFEN = startFEN; self.rookFiles = rookFiles; self.moves = moves
        self.humanColor = humanColor; self.difficulty = difficulty; self.result = result
        self.mode = mode
    }

    /// Rebuild the starting position (restoring Chess960 rook files).
    public func startPosition() -> Position? {
        guard var pos = Position(fen: startFEN) else { return nil }
        var map: [Character: Int] = [:]
        for (k, v) in rookFiles { if let c = k.first { map[c] = v } }
        if !map.isEmpty { pos.castleRookFile = map }
        return pos
    }
}

/// On-disk store for one app's saved games: a single autosave slot plus named slots.
/// Each app has its own Documents directory, so games never collide between apps.
@MainActor
public final class GameStore: ObservableObject {
    @Published public private(set) var autosave: SavedGame?
    @Published public private(set) var slots: [SavedGame] = []
    /// Every game played (newest first), for replay. Capped to a sensible size.
    @Published public private(set) var history: [SavedGame] = []

    private let fileURL: URL
    private let historyCap = 250

    public init(filename: String = "chesskit_games.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = dir.appendingPathComponent(filename)
        load()
        loadFavorites()
    }

    private struct Disk: Codable { var autosave: SavedGame?; var slots: [SavedGame]; var history: [SavedGame]? }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        autosave = disk.autosave
        slots = disk.slots
        history = disk.history ?? []
    }

    private func persist() {
        let disk = Disk(autosave: autosave, slots: slots, history: history)
        if let data = try? JSONEncoder().encode(disk) { try? data.write(to: fileURL) }
    }

    /// Record a played game into the replayable history (replacing a same-id entry).
    public func recordHistory(_ game: SavedGame) {
        guard !game.moves.isEmpty else { return }
        if let i = history.firstIndex(where: { $0.id == game.id }) { history[i] = game }
        else { history.insert(game, at: 0) }
        history.sort { $0.date > $1.date }
        if history.count > historyCap { history.removeLast(history.count - historyCap) }
        persist()
    }

    public func deleteHistory(_ game: SavedGame) {
        history.removeAll { $0.id == game.id }
        persist()
    }

    // MARK: Favorite Chess960 starting positions

    @Published public private(set) var favoritePositions: [Int] = []

    public func toggleFavorite(_ id: Int) {
        if let i = favoritePositions.firstIndex(of: id) { favoritePositions.remove(at: i) }
        else { favoritePositions.insert(id, at: 0) }
        persistFavorites()
    }
    public func isFavorite(_ id: Int) -> Bool { favoritePositions.contains(id) }

    private var favoritesURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("ck_fav_positions.json")
    }
    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favoritePositions) { try? data.write(to: favoritesURL) }
    }
    private func loadFavorites() {
        if let data = try? Data(contentsOf: favoritesURL),
           let ids = try? JSONDecoder().decode([Int].self, from: data) { favoritePositions = ids }
    }

    public func setAutosave(_ game: SavedGame?) { autosave = game; persist() }
    public func clearAutosave() { autosave = nil; persist() }

    /// Save a named slot (replaces a slot with the same id if present).
    public func save(_ game: SavedGame) {
        if let i = slots.firstIndex(where: { $0.id == game.id }) { slots[i] = game }
        else { slots.insert(game, at: 0) }
        slots.sort { $0.date > $1.date }
        persist()
    }

    public func delete(_ game: SavedGame) {
        slots.removeAll { $0.id == game.id }
        persist()
    }
}
