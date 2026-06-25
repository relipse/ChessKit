import Foundation

/// Losers Chess: the goal is inverted — you **win by getting checkmated**. And if you
/// have a capture available, you must take it (compulsory capture). Otherwise the moves
/// are ordinary legal chess moves.
public struct LosersChess: ChessVariant {
    public init() {}
    public var name: String { "Losers" }
    public var blurb: String { "Get checkmated to win — and if you can capture, you must." }

    public func legalMoves(_ pos: Position) -> [Move] {
        let legal = StandardChess.legalStandardMoves(pos)
        let captures = legal.filter { LosersChess.isCapture($0, in: pos) }
        return captures.isEmpty ? legal : captures
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    public func status(_ pos: Position) -> GameStatus {
        if legalMoves(pos).isEmpty {
            // Inverted: the player who is checkmated WINS.
            if pos.inCheck(pos.sideToMove) { return .variantWin(winner: pos.sideToMove, reason: "checkmated — you win!") }
            return .draw(reason: "Stalemate")
        }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    /// Inverted evaluation: shedding material and getting mated is *good*.
    public func evaluate(_ pos: Position) -> Int {
        -pos.material() - centralBonus(pos)
    }

    static func isCapture(_ move: Move, in pos: Position) -> Bool {
        guard !move.isDrop else { return false }
        if pos.squares[move.to] != nil { return true }
        if let p = pos.squares[move.from], p.kind == .pawn, move.to == pos.enPassant { return true }
        return false
    }
}
