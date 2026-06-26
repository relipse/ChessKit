import Foundation

/// My Turn Chess: real-time chess with no alternating turns. Both armies are live at
/// once — either side may move at any moment, and whoever completes a legal move first
/// has it registered. There is no "wait your turn" lock.
///
/// Interpretation (single device, two players sharing one board): turn order is not
/// enforced. Pick up a piece of either colour and move it; the side to move simply
/// follows whichever army you touch. The chess rules themselves are entirely orthodox —
/// moves must be legal (you can't leave your own king in check), and the game ends on
/// **checkmate or stalemate** (and the usual draws) just like normal chess. The only
/// twist is that there is no "wait your turn" lock: either side may move at any moment.
public struct MyTurnChess: ChessVariant {
    public init() {}
    public var name: String { "My Turn Chess" }
    public var blurb: String {
        "Real-time chess — no turns! Both armies move at once; grab any piece and go."
    }
    /// Real-time (no turn lock) in every mode — vs Computer (throttled AI), 2 players on one
    /// device, and nearby/internet (live relay).
    public var isRealtime: Bool { true }

    // MARK: How checks work (player-configurable in Settings)

    /// Checks are awkward when there are no turns, so the player picks how they behave.
    public enum WinRule: String, CaseIterable, Sendable, Identifiable {
        /// Orthodox: only legal moves (no moving into check); checkmate or stalemate ends it.
        case checkmate
        /// Blitz: check is ignored; you win by capturing the enemy king outright.
        case kingCapture
        public var id: String { rawValue }
        public var title: String { self == .checkmate ? "Checkmate" : "King Capture" }
        public var detail: String {
            switch self {
            case .checkmate:   return "Orthodox rules — you can't move into check, and checkmate or stalemate ends the game."
            case .kingCapture: return "Blitz rules — check is ignored; just grab the enemy king to win."
            }
        }
    }
    /// UserDefaults key shared by the Settings UI and the rule lookup below.
    public static let winRuleKey = "ck.myturn.winRule"
    /// The current rule (defaults to King Capture — the most natural fit for a no-turns
    /// scramble). Read live so a change in Settings applies to the next position evaluated.
    public static var winRule: WinRule {
        UserDefaults.standard.string(forKey: winRuleKey).flatMap(WinRule.init(rawValue:)) ?? .kingCapture
    }

    /// Moves offered to the side to move. In Checkmate mode these are orthodox legal moves;
    /// in King-Capture mode they're pseudo-legal (you may ignore check and take the king).
    public func legalMoves(_ pos: Position) -> [Move] {
        Self.winRule == .kingCapture ? StandardRules.pseudoMoves(pos)
                                     : StandardChess.legalStandardMoves(pos)
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    /// Game-over detection. Crucially, **stalemate never ends the game** here: with no turns,
    /// a side that has no legal move isn't drawn — it simply can't move while the opponent plays
    /// on. Checkmate mode still ends on a true mate; King-Capture mode ends when a king is taken.
    /// Both fall back to the 50-move clock so a stuck position can't run forever.
    public func status(_ pos: Position) -> GameStatus {
        if Self.winRule == .kingCapture {
            if pos.kingSquare(.white) == nil { return .variantWin(winner: .black, reason: "White king captured") }
            if pos.kingSquare(.black) == nil { return .variantWin(winner: .white, reason: "Black king captured") }
        } else {
            // Checkmate, but not stalemate: only a side that is *in check* with no legal move loses.
            if pos.inCheck(pos.sideToMove), legalMoves(pos).isEmpty {
                return .checkmate(winner: pos.sideToMove.opposite)
            }
        }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    /// Material plus a strong reward for hunting the enemy king down — this is what makes the
    /// real-time computer press an attack instead of shuffling.
    public func evaluate(_ pos: Position) -> Int {
        var score = pos.material() + centralBonus(pos)
        if let wk = pos.kingSquare(.white), let bk = pos.kingSquare(.black) {
            score += kingHunt(pos, enemyKing: bk, by: .white)   // White crowding Black's king is good for White
            score -= kingHunt(pos, enemyKing: wk, by: .black)   // Black crowding White's king is bad for White
        }
        return score
    }

    /// Reward `attacker`'s pieces for closing in on `enemyKing`. Pieces score more the nearer
    /// they are (Chebyshev distance), so the engine marches the army at the king.
    private func kingHunt(_ pos: Position, enemyKing: Int, by attacker: PieceColor) -> Int {
        let kf = enemyKing % 8, kr = enemyKing / 8
        var s = 0
        for sq in 0..<64 {
            guard let p = pos.squares[sq], p.color == attacker, p.kind != .king else { continue }
            let d = max(abs(sq % 8 - kf), abs(sq / 8 - kr))   // 0…7
            let weight = p.kind == .pawn ? 4 : 9              // major/minor pieces hunt harder
            s += (7 - d) * weight
        }
        return s
    }
}
