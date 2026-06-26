import Foundation

/// My Turn Chess: real-time chess with no alternating turns. Both armies are live at
/// once — either side may move at any moment, and whoever completes a legal move first
/// has it registered. There is no "wait your turn" lock.
///
/// Interpretation (single device, two players sharing one board): turn order is not
/// enforced. Pick up a piece of either colour and move it; the side to move simply
/// follows whichever army you touch. Because nobody is ever forced to answer a check,
/// the only coherent win condition is **capturing the enemy king** — checkmate and
/// stalemate don't apply when either player can keep moving. Pieces still move by the
/// ordinary chess rules (including castling, promotion and en passant).
///
/// Real-time play is driven by `GameMode.realtime`; the rules below are orthodox apart
/// from the win condition, so the variant is also perfectly well-defined in the
/// turn-based modes (vs Computer / 2 Players / Watch) where it plays as "king-capture
/// chess".
public struct MyTurnChess: ChessVariant {
    public init() {}
    public var name: String { "My Turn Chess" }
    public var blurb: String {
        "Real-time chess — no turns! Both armies move at once; grab any piece and go. Capture the enemy king to win."
    }

    /// Every pseudo-legal move for the side to move. Unlike orthodox chess we do NOT filter
    /// out moves that leave your own king in check — check is never binding when the
    /// opponent isn't obliged to wait for you — and capturing the enemy king is allowed
    /// (that's how a game is won).
    public func legalMoves(_ pos: Position) -> [Move] {
        StandardRules.pseudoMoves(pos)
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    /// The game ends only when a king is captured (or the 50-move clock runs out). There is
    /// no checkmate or stalemate because neither side is forced to respond to a threat.
    public func status(_ pos: Position) -> GameStatus {
        if pos.kingSquare(.white) == nil { return .variantWin(winner: .black, reason: "White king captured") }
        if pos.kingSquare(.black) == nil { return .variantWin(winner: .white, reason: "Black king captured") }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    /// Material plus a nudge to crowd the enemy king (the only target that ends the game).
    public func evaluate(_ pos: Position) -> Int {
        var score = pos.material() + centralBonus(pos)
        if let wk = pos.kingSquare(.white), let bk = pos.kingSquare(.black) {
            score -= kingPressure(pos, king: bk, by: .white)   // pressuring Black's king favours White
            score += kingPressure(pos, king: wk, by: .black)
        }
        return score
    }

    /// Rough count of `attacker`'s pieces lurking near `king` — reward hunting the king down.
    private func kingPressure(_ pos: Position, king: Int, by attacker: PieceColor) -> Int {
        let f = king % 8, r = king / 8
        var n = 0
        for df in -2...2 { for dr in -2...2 {
            let ff = f + df, rr = r + dr
            guard ff >= 0, ff < 8, rr >= 0, rr < 8 else { continue }
            if let p = pos.squares[rr * 8 + ff], p.color == attacker, p.kind != .king { n += 4 }
        } }
        return n
    }
}
