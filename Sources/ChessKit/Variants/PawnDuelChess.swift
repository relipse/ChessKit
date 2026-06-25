import Foundation

/// Pawn Duel: a stripped-down skirmish — each side starts with just a king and three
/// pawns tucked into opposite corners. Ordinary chess rules; race a pawn to the far
/// side to promote, then hunt the enemy king.
public struct PawnDuelChess: ChessVariant {
    public init() {}
    public var name: String { "Pawn Duel" }
    public var blurb: String {
        "A king and three pawns in opposite corners — promote a pawn and checkmate to win."
    }

    /// Black king c8 + a7/b7/c7 pawns vs White king f1 + f2/g2/h2 pawns.
    /// The kings sit two squares in from the corner (one file toward the enemy
    /// pawns) so each king is inside the "square" of the opponent's edge pawn: if
    /// that side pawn is pushed first, the king arrives on the promotion square
    /// exactly in time to capture the new queen. One file closer to the corner and
    /// the edge pawn would promote uncaught.
    public static let startFEN = "2k5/ppp5/8/8/8/8/5PPP/5K2 w - - 0 1"

    public func startPosition() -> Position { Position(fen: PawnDuelChess.startFEN)! }
    public func legalMoves(_ pos: Position) -> [Move] { StandardChess.legalStandardMoves(pos) }
    public func make(_ move: Move, in pos: Position) -> Position { StandardRules.apply(move, to: pos).position }
    public func status(_ pos: Position) -> GameStatus { StandardChess.standardStatus(pos, variant: self) }

    /// Material alone is a flat line in a pure pawn race, so the engine would shuffle and let an
    /// edge pawn run. This evaluation rewards pushing pawns AND keeps each king inside the "square"
    /// of the enemy's most-advanced pawn — so the computer chases a runaway pawn instead of ignoring it.
    public func evaluate(_ pos: Position) -> Int {
        var score = pos.material()
        var white: [Int] = [], black: [Int] = []
        for sq in 0..<64 {
            guard let p = pos.squares[sq], p.kind == .pawn else { continue }
            if p.color == .white { white.append(sq) } else { black.append(sq) }
        }
        for sq in white { score += Self.advance(sq / 8) }              // White promotes upward (rank 7)
        for sq in black { score -= Self.advance(7 - sq / 8) }          // Black promotes downward (rank 0)
        guard let wk = pos.kingSquare(.white), let bk = pos.kingSquare(.black) else { return score }
        // White king must stop Black's pawns (promote at rank 0); Black king stops White's (rank 7).
        score -= Self.runnerThreat(black, king: wk, promoteRank: 0, defenderToMove: pos.sideToMove == .white)
        score += Self.runnerThreat(white, king: bk, promoteRank: 7, defenderToMove: pos.sideToMove == .black)
        return score
    }

    private static func advance(_ adv: Int) -> Int {
        let table = [0, 4, 12, 28, 60, 130, 280, 0]   // ranks advanced (6 = one square from promoting)
        return table[max(0, min(7, adv))]
    }
    private static func chebyshev(_ a: Int, _ b: Int) -> Int { max(abs(a % 8 - b % 8), abs(a / 8 - b / 8)) }

    /// Penalty (from the defender's view) for the enemy's most dangerous pawn: huge if it's
    /// outside the king's square (unstoppable), plus a proximity nudge so the king keeps chasing.
    private static func runnerThreat(_ pawns: [Int], king: Int, promoteRank: Int, defenderToMove: Bool) -> Int {
        guard !pawns.isEmpty else { return 0 }
        let startRank = promoteRank == 0 ? 6 : 1
        var threat = 0
        for sq in pawns {
            let f = sq % 8, r = sq / 8
            let promoSq = promoteRank * 8 + f
            let dist = abs(r - promoteRank)
            let pawnMoves = (r == startRank) ? dist - 1 : dist        // double-step from home
            // King catches it if it can reach the promotion square in time; it gets one extra
            // tempo when it's the defender's move (the square-of-the-pawn rule).
            let budget = pawnMoves + (defenderToMove ? 1 : 0)
            if chebyshev(king, promoSq) > budget { threat = max(threat, 760 - pawnMoves * 70) }  // unstoppable
        }
        // Stay near the most-advanced enemy pawn (encourages chasing even when still catchable).
        let runner = pawns.min { (promoteRank == 0 ? $0 / 8 : 7 - $0 / 8) < (promoteRank == 0 ? $1 / 8 : 7 - $1 / 8) }!
        threat += chebyshev(king, runner) * 5
        return threat
    }
}
