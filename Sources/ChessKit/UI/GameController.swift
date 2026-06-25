import SwiftUI

/// Drives a human-vs-computer game of any `ChessVariant`. Owns the position, move
/// history, selection state, the AI opponent, and (for Kriegspiel) the referee.
@MainActor
public final class GameController: ObservableObject {
    public let variant: ChessVariant

    @Published public private(set) var position: Position
    @Published public private(set) var history: [Move] = []
    @Published public private(set) var sanHistory: [String] = []
    @Published public private(set) var status: GameStatus = .ongoing
    @Published public private(set) var lastMove: (from: Int, to: Int)?
    @Published public private(set) var thinking = false

    // Player setup.
    @Published public var humanColor: PieceColor
    @Published public var difficulty: Difficulty {
        didSet { defaults.set(difficulty.level, forKey: "ck.difficultyLevel") }
    }
    public var flipped: Bool { humanColor == .black }

    // Tap-to-move selection state.
    @Published public var selected: Int?
    @Published public var targets: Set<Int> = []
    @Published public var pocketSelection: PieceKind?
    @Published public var pendingPromotion: (from: Int, to: Int)?

    // Kriegspiel umpire.
    public let referee = KriegspielReferee()
    @Published public private(set) var umpireLog: [String] = []
    @Published public private(set) var lastVerdictIllegal = false

    private let defaults: UserDefaults
    private var engine: SearchEngine
    /// The position the current game started from (needed to save/replay, esp. Chess960).
    public private(set) var initialPosition: Position
    /// Stable id for the current game so history/slots update one entry, not duplicates.
    private var gameID = UUID()
    /// Shared store for autosave + named slots (nil → no persistence).
    public let store: GameStore?
    /// Game Center leaderboard to submit wins to.
    public var leaderboardID: String?

    public init(variant: ChessVariant, humanColor: PieceColor = .white,
                difficulty: Difficulty? = nil, suite: String? = nil,
                store: GameStore? = nil, restore saved: SavedGame? = nil,
                leaderboardID: String? = nil) {
        self.variant = variant
        self.leaderboardID = leaderboardID
        let d = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.defaults = d
        self.store = store
        let storedLevel = d.object(forKey: "ck.difficultyLevel") as? Int
        let diff = saved?.difficulty
            ?? difficulty
            ?? storedLevel.map(Difficulty.init(level:))
            ?? .medium
        self.difficulty = diff
        self.humanColor = saved?.humanColor ?? humanColor
        let start = saved?.startPosition() ?? variant.startPosition()
        self.initialPosition = start
        self.position = start
        self.engine = SearchEngine(variant: variant, difficulty: diff)
        if let saved { gameID = saved.id; replay(saved.moves) }
    }

    /// Replay a move list from `initialPosition`, rebuilding all derived state.
    private func replay(_ moves: [Move]) {
        position = initialPosition
        history.removeAll(); sanHistory.removeAll(); lastMove = nil
        for move in moves {
            sanHistory.append(StandardRules.san(for: move, in: position))
            position = variant.make(move, in: position)
            history.append(move)
            lastMove = move.isDrop ? nil : (move.from, move.to)
        }
        status = variant.status(position)
        if !status.isOver, position.sideToMove != humanColor { maybeStartAI() }
    }

    public var isHumanTurn: Bool { position.sideToMove == humanColor && !status.isOver }
    public var checkSquare: Int? {
        guard !variant.hidesOpponentPieces else { return nil }
        let stm = position.sideToMove
        return position.inCheck(stm) ? position.kingSquare(stm) : nil
    }

    // MARK: New game

    public func newGame(humanColor: PieceColor? = nil, difficulty: Difficulty? = nil) {
        if let c = humanColor { self.humanColor = c }
        if let d = difficulty { self.difficulty = d }
        engine = SearchEngine(variant: variant, difficulty: self.difficulty)
        gameID = UUID()
        let start = variant.startPosition()
        initialPosition = start
        position = start
        history.removeAll(); sanHistory.removeAll(); umpireLog.removeAll()
        status = .ongoing; lastMove = nil; clearSelection(); lastVerdictIllegal = false
        store?.clearAutosave()
        maybeStartAI()
    }

    // MARK: Save / load

    /// Build a serialisable snapshot of the current game.
    public func toSaved(name: String) -> SavedGame {
        var rookFiles: [String: Int] = [:]
        for (k, v) in initialPosition.castleRookFile { rookFiles[String(k)] = v }
        return SavedGame(id: gameID, name: name, date: savedDate(), variantName: variant.name,
                         startFEN: initialPosition.fen(), rookFiles: rookFiles,
                         moves: history, humanColor: humanColor, difficulty: difficulty,
                         result: status.isOver ? resultText : nil)
    }

    /// Log the current game into the replayable history (call on game over or when leaving).
    public func recordToHistory() {
        guard !history.isEmpty else { return }
        store?.recordHistory(toSaved(name: status.isOver ? resultText : defaultSaveName()))
    }

    /// Persist the current game to a named slot.
    public func saveSlot(name: String) { store?.save(toSaved(name: name)) }

    /// A sensible default slot name, e.g. "Crazyhouse · 12 moves".
    public func defaultSaveName() -> String { "\(variant.name) · \(history.count) moves" }

    /// Best-effort timestamp (Date() is fine in app context).
    private func savedDate() -> Date { Date() }

    private func autosave() {
        guard let store else { return }
        if status.isOver || history.isEmpty { store.clearAutosave() }
        else { store.setAutosave(toSaved(name: "Autosave")) }
    }

    // MARK: Human interaction

    /// Handle a tap on board square `sq`.
    public func tap(_ sq: Int) {
        guard isHumanTurn else { return }
        lastVerdictIllegal = false

        // A pocket piece is armed → this tap is a drop target.
        if let kind = pocketSelection {
            let move = Move(drop: kind, to: sq)
            if targets.contains(sq) { commitHuman(move) }
            clearSelection()
            return
        }

        if let from = selected {
            // Castling: tap the king's destination *or* your own castling rook (Chess960-friendly).
            if let castle = castleMove(from: from, tapped: sq) {
                commitHuman(castle); clearSelection(); return
            }
            if sq == from { clearSelection(); return }
            if targets.contains(sq) {
                attemptMove(from: from, to: sq)
                return
            }
        }
        // Select one of the human's own pieces.
        if let p = position.squares[sq], p.color == humanColor {
            selected = sq
            pocketSelection = nil
            if variant.hidesOpponentPieces {
                // Kriegspiel: the player can't see the enemy, so offer every pseudo-legal
                // destination — the referee decides legality.
                targets = Set(pseudoDestinations(from: sq))
            } else {
                let legal = variant.legalMoves(from: sq, in: position)
                var t = Set(legal.map(\.to))
                // Also highlight the rook you can castle with.
                for m in legal where m.castle != nil { t.insert(castleRookSquare(for: m)) }
                targets = t
            }
        } else {
            clearSelection()
        }
    }

    /// If `from` is the king and `tapped` is either a castle destination or the matching
    /// castling rook, return that castle move.
    private func castleMove(from: Int, tapped: Int) -> Move? {
        guard position.squares[from]?.kind == .king else { return nil }
        let castles = variant.legalMoves(from: from, in: position).filter { $0.castle != nil }
        return castles.first { $0.to == tapped || castleRookSquare(for: $0) == tapped }
    }

    private func castleRookSquare(for move: Move) -> Int {
        let r = position.sideToMove == .white ? 0 : 7
        let right: Character = position.sideToMove == .white
            ? (move.castle == .king ? "K" : "Q") : (move.castle == .king ? "k" : "q")
        return r * 8 + (position.castleRookFile[right] ?? (move.castle == .king ? 7 : 0))
    }

    /// Drag-and-drop entry point: move the piece on `from` to `to` in one gesture.
    public func move(from: Int, to: Int) {
        guard isHumanTurn else { return }
        pocketSelection = nil
        if selected != from {
            // Select the origin piece (lights up legal targets) without toggling it off.
            if let p = position.squares[from], p.color == humanColor { tap(from) }
        }
        guard selected == from else { return }
        tap(to)
    }

    /// Drop an armed pocket piece on `to` (drag from the reserve).
    public func drop(_ kind: PieceKind, to sq: Int) {
        guard isHumanTurn, variant.usesPockets else { return }
        guard (position.pockets[humanColor]?.count(kind) ?? 0) > 0 else { return }
        let move = Move(drop: kind, to: sq)
        if variant.legalDrops(of: kind, in: position).contains(where: { $0.to == sq }) {
            commitHuman(move)
        }
        clearSelection()
    }

    /// Arm a pocket piece for dropping (Crazyhouse).
    public func selectPocket(_ kind: PieceKind) {
        guard isHumanTurn, variant.usesPockets else { return }
        guard (position.pockets[humanColor]?.count(kind) ?? 0) > 0 else { return }
        selected = nil
        if pocketSelection == kind { clearSelection(); return }
        pocketSelection = kind
        targets = Set(variant.legalDrops(of: kind, in: position).map(\.to))
    }

    private func attemptMove(from: Int, to: Int) {
        // Promotion?
        if let p = position.squares[from], p.kind == .pawn,
           (to / 8 == 7 || to / 8 == 0) {
            pendingPromotion = (from, to)
            return
        }
        commitHuman(Move(from: from, to: to))
        clearSelection()
    }

    public func choosePromotion(_ kind: PieceKind) {
        guard let pp = pendingPromotion else { return }
        commitHuman(Move(from: pp.from, to: pp.to, promotion: kind))
        pendingPromotion = nil
        clearSelection()
    }

    public func cancelPromotion() { pendingPromotion = nil; clearSelection() }

    private func clearSelection() {
        selected = nil; targets = []; pocketSelection = nil
    }

    // MARK: Applying moves

    /// Map a raw (from,to,promotion) to the exact legal move, picking up castle flags etc.
    private func resolve(_ move: Move) -> Move {
        guard !move.isDrop, move.castle == nil else { return move }
        let legal = variant.legalMoves(position)
        return legal.first {
            $0.from == move.from && $0.to == move.to && $0.promotion == move.promotion
        } ?? move
    }

    private func commitHuman(_ rawMove: Move) {
        let move = resolve(rawMove)
        if variant.hidesOpponentPieces {
            // Kriegspiel: the referee rules on the attempt; illegal attempts cost no turn.
            let verdict = referee.adjudicate(move, in: position)
            guard verdict.legal else {
                lastVerdictIllegal = true
                umpireLog.append("⛔︎ \(verdict.announcement)")
                return
            }
            if !verdict.announcement.isEmpty { umpireLog.append("You: \(verdict.announcement)") }
        } else {
            guard variant.legalMoves(position).contains(move) else { return }
        }
        apply(move)
        maybeStartAI()
    }

    private func apply(_ move: Move) {
        sanHistory.append(StandardRules.san(for: move, in: position))
        position = variant.make(move, in: position)
        history.append(move)
        lastMove = move.isDrop ? nil : (move.from, move.to)
        status = variant.status(position)
        autosave()
        if status.isOver {
            recordToHistory()
            if humanWon {
                GameCenter.shared.submitWin(leaderboardID: leaderboardID,
                                            difficulty: difficulty, moves: history.count)
            }
        }
    }

    // MARK: AI opponent

    private func maybeStartAI() {
        guard !status.isOver, position.sideToMove != humanColor else { return }
        thinking = true
        let snapshot = position
        let engine = self.engine
        let hidden = variant.hidesOpponentPieces
        Task { [weak self] in
            // Compute off the main actor; small artificial floor so it never feels instant.
            async let move: Move? = Task.detached(priority: .userInitiated) {
                engine.bestMove(in: snapshot)
            }.value
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, let chosen = await move else { self?.thinking = false; return }
            guard self.position == snapshot else { return }   // game reset mid-think
            if hidden { self.announceOpponentMove(chosen) }
            self.apply(chosen)
            self.thinking = false
        }
    }

    /// For Kriegspiel: tell the blind human only what a referee would reveal about the AI's move.
    private func announceOpponentMove(_ move: Move) {
        let verdict = referee.adjudicate(move, in: position)
        var parts: [String] = []
        if verdict.capture, let sq = verdict.captureSquare { parts.append("Your piece on \(squareName(sq)) is captured.") }
        for c in verdict.checks { parts.append("Check \(c.rawValue).") }
        if parts.isEmpty { parts.append("Opponent has moved.") }
        umpireLog.append("Umpire: \(parts.joined(separator: " "))")
        // Offer the human their pawn tries on the reply.
        let tries = referee.pawnTryCount(in: variant.make(move, in: position))
        if tries > 0 { umpireLog.append("Umpire: \(tries) pawn \(tries == 1 ? "try" : "tries") — Any?") }
    }

    private var armedAtStart = false
    private func maybeStartAtBoot() {}

    /// Call once after init if the human is Black so the AI opens.
    public func startIfAIOpens() {
        guard !armedAtStart else { return }
        armedAtStart = true
        maybeStartAI()
    }

    // MARK: Helpers

    /// Pseudo-legal destinations from a square ignoring own-king safety (Kriegspiel offers these).
    private func pseudoDestinations(from sq: Int) -> [Int] {
        guard let p = position.squares[sq], p.color == humanColor else { return [] }
        var out = position.pseudoTargets(from: sq).filter { position.squares[$0]?.color != humanColor }
        if p.kind == .king { out += StandardRules.castlingMoves(position).filter { $0.from == sq }.map(\.to) }
        return out
    }

    /// Human-readable result line.
    public var resultText: String {
        switch status {
        case .ongoing: return ""
        case .checkmate(let w): return "\(w == .white ? "White" : "Black") wins by checkmate"
        case .variantWin(let w, let why): return "\(w == .white ? "White" : "Black") wins — \(why)"
        case .stalemate: return "Draw — stalemate"
        case .draw(let why): return "Draw — \(why)"
        }
    }
    public var humanWon: Bool { status.winner == humanColor }
}
