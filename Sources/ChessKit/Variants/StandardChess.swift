import Foundation

/// Orthodox chess. Also the rules base shared by Kriegspiel (same rules, hidden info).
public struct StandardChess: ChessVariant {
    public init() {}
    public var name: String { "Chess" }
    public var blurb: String { "Standard chess — checkmate the king." }

    public func legalMoves(_ pos: Position) -> [Move] {
        StandardChess.legalStandardMoves(pos)
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    public func status(_ pos: Position) -> GameStatus {
        StandardChess.standardStatus(pos, variant: self)
    }

    // MARK: Shared helpers (reused by Kriegspiel)

    /// Pseudo-legal moves filtered so the mover's king is not left in check.
    public static func legalStandardMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        return StandardRules.pseudoMoves(pos).filter { move in
            let next = StandardRules.apply(move, to: pos).position
            guard let ks = next.kingSquare(me) else { return false }
            return !next.isSquareAttacked(ks, by: me.opposite)
        }
    }

    /// Standard end-of-game detection (checkmate / stalemate / 50-move / insufficient material).
    public static func standardStatus(_ pos: Position, variant: ChessVariant) -> GameStatus {
        if variant.legalMoves(pos).isEmpty {
            if pos.inCheck(pos.sideToMove) {
                return .checkmate(winner: pos.sideToMove.opposite)
            }
            return .stalemate
        }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        if insufficientMaterial(pos) { return .draw(reason: "Insufficient material") }
        return .ongoing
    }

    static func insufficientMaterial(_ pos: Position) -> Bool {
        var minors = 0
        for p in pos.squares.compactMap({ $0 }) {
            switch p.kind {
            case .king: continue
            case .bishop, .knight: minors += 1
            default: return false   // a pawn / rook / queen → not insufficient
            }
        }
        return minors <= 1
    }
}
