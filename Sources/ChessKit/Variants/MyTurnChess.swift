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
        "Real-time chess — no turns! Both armies move at once; grab any piece and go. Orthodox rules: checkmate or stalemate ends the game."
    }
    /// This variant is only ever played in real-time (no turns); it never offers the
    /// turn-based Computer / 2-Players / Watch / Nearby modes.
    public var isRealtimeOnly: Bool { true }

    /// Orthodox legal moves for the side to move (no moving into check, no king capture).
    public func legalMoves(_ pos: Position) -> [Move] {
        StandardChess.legalStandardMoves(pos)
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    /// Standard endings: checkmate, stalemate and the usual draws end the game.
    public func status(_ pos: Position) -> GameStatus {
        StandardChess.standardStatus(pos, variant: self)
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
