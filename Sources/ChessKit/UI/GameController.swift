import SwiftUI

/// How a game is being played.
public enum GameMode: String, Codable, Sendable {
    case computer      // one human vs the built-in AI
    case passAndPlay   // two humans sharing one device
    case nearby        // two humans on two nearby devices (MultipeerConnectivity)
    case watch         // computer vs computer — the human just watches
    case realtime      // two humans, one device, NO turn order — either army may move at any time (My Turn Chess)
}

/// Drives a game of any `ChessVariant` — vs the computer, pass-and-play, or nearby.
/// Owns the position, move history, selection state, the AI opponent, and (for
/// vs-computer Kriegspiel) the referee/fog of war.
@MainActor
public final class GameController: ObservableObject {
    public let variant: ChessVariant
    public let mode: GameMode
    /// In `.nearby`, the colour this device controls.
    public var localColor: PieceColor
    /// In `.nearby`, called after a local move so the transport can send it to the peer.
    public var onLocalMove: ((Move) -> Void)?

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
    public var flipped: Bool {
        switch mode {
        case .computer: return humanColor == .black
        case .nearby: return localColor == .black
        case .passAndPlay: return position.sideToMove == .black   // rotate to face the mover
        case .watch: return false                                 // fixed orientation while watching
        case .realtime: return false                              // both players share one fixed board
        }
    }

    /// Real-time ("My Turn Chess"): both armies are live on one device with no enforced
    /// turn order. The side to move simply follows whichever piece a player touches.
    public var isRealtime: Bool { mode == .realtime }
    /// Brief lockout after a real-time move so a single tap can't fire twice / machine-gun.
    public let realtimeCooldown: TimeInterval = 0.4
    private var lastRealtimeMoveAt: Date = .distantPast
    /// Fog of war applies to Kriegspiel both vs-computer and pass-and-play (hot-seat).
    /// In hot-seat we hide the *non-mover's* army and gate turns behind a handoff screen.
    /// (Two-device "nearby" can't safely hide because both sides observe the same relay.)
    var useKriegspielFog: Bool { variant.hidesOpponentPieces && (mode == .computer || mode == .passAndPlay) }

    /// True while we're waiting for the device to be handed to the next player (hot-seat
    /// Kriegspiel). The board is fully covered until the incoming player taps "reveal".
    @Published public private(set) var awaitingHandoff = false

    // Tap-to-move selection state.
    @Published public var selected: Int?
    @Published public var targets: Set<Int> = []
    @Published public var pocketSelection: PieceKind?
    @Published public var pendingPromotion: (from: Int, to: Int)?

    // Kriegspiel umpire.
    public let referee = KriegspielReferee()
    @Published public private(set) var umpireLog: [String] = []
    @Published public private(set) var lastVerdictIllegal = false

    // Forced-capture hint (Losers): set when the player picks a piece that can't capture
    // while a capture is compulsory. `mustCaptureSquares` are the pieces that *can* capture.
    @Published public private(set) var mustCaptureHint = false
    @Published public private(set) var mustCaptureSquares: Set<Int> = []

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
                leaderboardID: String? = nil, mode: GameMode = .computer,
                localColor: PieceColor = .white, startOverride: Position? = nil) {
        self.variant = variant
        self.mode = saved?.mode ?? mode
        self.localColor = localColor
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
        let start = saved?.startPosition() ?? startOverride ?? variant.startPosition()
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

    /// Whether the local user may move right now (the side they control is to move).
    public var isHumanTurn: Bool {
        guard !status.isOver else { return false }
        switch mode {
        case .computer: return position.sideToMove == humanColor
        case .nearby: return position.sideToMove == localColor
        case .passAndPlay: return true
        case .realtime: return true   // either army may move at any time
        case .watch: return false     // both sides are the computer
        }
    }
    public var checkSquare: Int? {
        // Check isn't binding in real-time (nobody must answer it), so don't flag it.
        guard !useKriegspielFog, mode != .realtime else { return nil }
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
        awaitingHandoff = false
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
                         result: status.isOver ? resultText : nil, mode: mode)
    }

    /// Log the current game into the replayable history (call on game over or when leaving).
    public func recordToHistory() {
        guard !history.isEmpty else { return }
        store?.recordHistory(toSaved(name: status.isOver ? resultText : defaultSaveName()))
    }

    /// Persist the current game to a named slot.
    public func saveSlot(name: String) { store?.save(toSaved(name: name)) }

    /// Worth offering to save when leaving? (has moves and isn't finished)
    public var isResumable: Bool { !history.isEmpty && !status.isOver }
    /// Forget the in-progress game so "Continue" won't offer it.
    public func discardAutosave() { store?.clearAutosave() }

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
        guard isHumanTurn, !awaitingHandoff else { return }
        if isRealtime, Date().timeIntervalSince(lastRealtimeMoveAt) < realtimeCooldown { return }
        // Real-time: both armies are live. With nothing selected yet, a tap on a piece of the
        // idle army makes that army the side to move, so the existing selection/move pipeline
        // (which keys off `sideToMove`) Just Works without any per-colour special-casing.
        if isRealtime, selected == nil, pocketSelection == nil,
           let p = position.squares[sq], p.color != position.sideToMove {
            position.sideToMove = p.color
        }
        lastVerdictIllegal = false
        mustCaptureHint = false; mustCaptureSquares = []

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
        // Select one of the side-to-move's own pieces.
        if let p = position.squares[sq], p.color == position.sideToMove {
            selected = sq
            pocketSelection = nil
            if useKriegspielFog {
                // Kriegspiel vs computer: offer every pseudo-legal destination — the referee decides.
                targets = Set(pseudoDestinations(from: sq))
            } else {
                let legal = variant.legalMoves(from: sq, in: position)
                // Forced capture (Losers): picked a piece that can't capture while a capture exists.
                if variant.forcesCapture, legal.isEmpty {
                    let capSquares = capturingPieceSquares()
                    if !capSquares.isEmpty {
                        selected = nil; targets = []
                        mustCaptureHint = true
                        mustCaptureSquares = capSquares
                        return
                    }
                }
                var t = Set(legal.map(\.to))
                // Also highlight the rook you can castle with.
                for m in legal where m.castle != nil { t.insert(castleRookSquare(for: m)) }
                targets = t
            }
        } else {
            clearSelection()
        }
    }

    /// Squares of the side-to-move's pieces that have a legal capture (for the forced-capture hint).
    private func capturingPieceSquares() -> Set<Int> {
        var out: Set<Int> = []
        for move in variant.legalMoves(position) where !move.isDrop {
            if position.squares[move.to] != nil
                || (position.squares[move.from]?.kind == .pawn && move.to == position.enPassant) {
                out.insert(move.from)
            }
        }
        return out
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
        guard isHumanTurn, !awaitingHandoff else { return }
        pocketSelection = nil
        if selected != from {
            // Select the origin piece (lights up legal targets) without toggling it off.
            // Real-time: either army may be dragged, so let `tap` pick the side to move.
            if isRealtime {
                if position.squares[from] != nil { tap(from) }
            } else if let p = position.squares[from], p.color == position.sideToMove { tap(from) }
        }
        guard selected == from else { return }
        tap(to)
    }

    /// Drop an armed pocket piece on `to` (drag from the reserve).
    public func drop(_ kind: PieceKind, to sq: Int) {
        guard isHumanTurn, !awaitingHandoff, variant.usesPockets else { return }
        guard (position.pockets[position.sideToMove]?.count(kind) ?? 0) > 0 else { return }
        let move = Move(drop: kind, to: sq)
        if variant.legalDrops(of: kind, in: position).contains(where: { $0.to == sq }) {
            commitHuman(move)
        }
        clearSelection()
    }

    /// Arm a pocket piece for dropping (Crazyhouse).
    public func selectPocket(_ kind: PieceKind) {
        guard isHumanTurn, variant.usesPockets else { return }
        guard (position.pockets[position.sideToMove]?.count(kind) ?? 0) > 0 else { return }
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
        if useKriegspielFog {
            // Kriegspiel: the referee rules on the attempt; illegal attempts cost no turn.
            let mover = position.sideToMove
            let verdict = referee.adjudicate(move, in: position)
            guard verdict.legal else {
                lastVerdictIllegal = true
                umpireLog.append("⛔︎ \(verdict.announcement)")
                return
            }
            if mode == .passAndPlay {
                announceHotSeatMove(verdict, mover: mover)
            } else if !verdict.announcement.isEmpty {
                umpireLog.append("You: \(verdict.announcement)")
            }
        } else {
            guard variant.legalMoves(position).contains(move) else { return }
        }
        apply(move)
        switch mode {
        case .computer: maybeStartAI()
        case .nearby: onLocalMove?(move)   // send to the peer
        case .passAndPlay:
            // Cover the board until the next player confirms they're holding the device.
            if useKriegspielFog, !status.isOver { awaitingHandoff = true }
        case .watch: break                 // AI drives both sides (chained from maybeStartAI)
        case .realtime: break              // no turn lock — the opponent may reply immediately
        }
    }

    /// Apply a move received from the nearby peer (their turn only).
    public func applyRemoteMove(_ rawMove: Move) {
        guard mode == .nearby, !status.isOver, position.sideToMove != localColor else { return }
        let move = resolve(rawMove)
        guard variant.legalMoves(position).contains(move) else { return }
        clearSelection()
        apply(move)
    }

    private func apply(_ move: Move) {
        sanHistory.append(StandardRules.san(for: move, in: position))
        position = variant.make(move, in: position)
        history.append(move)
        lastMove = move.isDrop ? nil : (move.from, move.to)
        status = variant.status(position)
        if isRealtime { lastRealtimeMoveAt = Date() }
        autosave()
        if status.isOver {
            recordToHistory()
            if mode == .computer, humanWon {
                GameCenter.shared.submitWin(leaderboardID: leaderboardID,
                                            difficulty: difficulty, moves: history.count)
            }
        }
    }

    // MARK: AI opponent

    private func maybeStartAI() {
        guard !status.isOver else { return }
        let aiToMove = (mode == .watch) || (mode == .computer && position.sideToMove != humanColor)
        guard aiToMove else { return }
        thinking = true
        let snapshot = position
        let engine = self.engine
        let hidden = variant.hidesOpponentPieces && mode == .computer   // no fog while watching
        let watching = mode == .watch
        Task { [weak self] in
            // Compute off the main actor; small artificial floor so it never feels instant.
            async let move: Move? = Task.detached(priority: .userInitiated) {
                engine.bestMove(in: snapshot)
            }.value
            // Move slower in watch mode so a human can follow along.
            let lo: UInt64 = watching ? 1_500_000_000 : 900_000_000
            let hi: UInt64 = watching ? 2_800_000_000 : 2_000_000_000
            try? await Task.sleep(nanoseconds: UInt64.random(in: lo...hi))
            guard let self, let chosen = await move else { self?.thinking = false; return }
            guard self.position == snapshot else { return }   // game reset mid-think
            if hidden { self.announceOpponentMove(chosen) }
            self.apply(chosen)
            self.thinking = false
            if self.mode == .watch { self.maybeStartAI() }   // chain — the other side moves next
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

    /// Hot-seat Kriegspiel: log the umpire's public calls — what a real referee says aloud to
    /// the room. Captures and checks are announced (positions are never revealed), then the
    /// next player is told whose move it is and how many pawn tries they have.
    private func announceHotSeatMove(_ v: KriegspielReferee.Verdict, mover: PieceColor) {
        let next = mover.opposite
        var parts: [String] = []
        if v.capture, let sq = v.captureSquare { parts.append("Capture on \(squareName(sq)).") }
        for c in v.checks { parts.append("Check \(c.rawValue).") }
        let label = mover == .white ? "White" : "Black"
        umpireLog.append("\(label): " + (parts.isEmpty ? "No capture, no check." : parts.joined(separator: " ")))

        let nextLabel = next == .white ? "White" : "Black"
        var nextParts = ["\(nextLabel) to move."]
        if v.pawnTries > 0 { nextParts.append("\(v.pawnTries) pawn \(v.pawnTries == 1 ? "try" : "tries") — Any?") }
        umpireLog.append("Umpire: " + nextParts.joined(separator: " "))
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
        let me = position.sideToMove
        guard let p = position.squares[sq], p.color == me else { return [] }
        var out = position.pseudoTargets(from: sq).filter { position.squares[$0]?.color != me }
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

    /// The colour to hide on the board. vs-computer: always the opponent of the human.
    /// Hot-seat: the side that is *not* to move (so the player holding the phone sees only
    /// their own army). Once the game is over the fog lifts and the full board is revealed.
    public var fogColor: PieceColor? {
        guard useKriegspielFog, !status.isOver else { return nil }
        switch mode {
        case .computer:    return humanColor.opposite
        case .passAndPlay: return position.sideToMove.opposite
        default:           return nil
        }
    }

    /// The last-move highlight to actually display. In Kriegspiel we must never reveal the
    /// hidden side's move — the mover's piece now sits on `to`, so if that square holds a
    /// fogged piece we suppress the highlight entirely.
    public var displayLastMove: (from: Int, to: Int)? {
        guard let lm = lastMove else { return nil }
        if let fog = fogColor, position.squares[lm.to]?.color == fog { return nil }
        return lm
    }

    /// Called by the handoff overlay once the next player confirms they're holding the device.
    public func confirmHandoff() {
        awaitingHandoff = false
        clearSelection()
        lastVerdictIllegal = false
    }

    /// Status-bar label for whose turn it is, mode-aware.
    public var turnLabel: String {
        if status.isOver { return "" }
        switch mode {
        case .computer: return isHumanTurn ? "YOUR MOVE" : "…"
        case .passAndPlay: return position.sideToMove == .white ? "WHITE TO MOVE" : "BLACK TO MOVE"
        case .nearby: return isHumanTurn ? "YOUR MOVE" : "OPPONENT'S MOVE"
        case .watch: return position.sideToMove == .white ? "WHITE…" : "BLACK…"
        case .realtime: return "GO — EITHER SIDE MOVES"
        }
    }
}
