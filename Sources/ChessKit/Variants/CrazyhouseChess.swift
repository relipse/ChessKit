import Foundation

/// Crazyhouse: captured enemy pieces switch sides and may be re-dropped onto the board
/// on a later turn. A promoted pawn reverts to a pawn when captured.
public struct CrazyhouseChess: ChessVariant {
    public init() {}
    public var name: String { "Crazyhouse" }
    public var blurb: String { "Capture a piece and it joins your reserve — drop it back into the fight." }
    public var usesPockets: Bool { true }

    public func legalMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        var moves = StandardChess.legalStandardMoves(pos)
        // Drops: any pocket kind onto any empty square (pawns not on the back ranks),
        // filtered so the drop does not leave the mover's own king in check.
        let pocket = pos.pockets[me] ?? Pocket()
        for kind in pocket.kindsAvailable {
            for sq in 0..<64 where pos.squares[sq] == nil {
                if kind == .pawn, sq / 8 == 0 || sq / 8 == 7 { continue }
                let move = Move(drop: kind, to: sq)
                let next = make(move, in: pos)
                if let ks = next.kingSquare(me), !next.isSquareAttacked(ks, by: me.opposite) {
                    moves.append(move)
                }
            }
        }
        return moves
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        let mover = pos.sideToMove
        if let kind = move.dropKind {
            var p = pos
            p.squares[move.to] = Piece(color: mover, kind: kind)
            p.pockets[mover]?.remove(kind)
            p.promoted.remove(move.to)   // a dropped piece is a genuine piece, not a promoted pawn
            p.enPassant = nil
            p.halfmoveClock += 1
            StandardRules.advanceSide(&p)
            return p
        }
        let applied = StandardRules.apply(move, to: pos)
        var p = applied.position
        if let cap = applied.captured, let csq = applied.capturedSquare {
            // Promoted pawns revert to pawns in the pocket.
            let pocketKind: PieceKind = pos.promoted.contains(csq) ? .pawn : cap.kind
            p.pockets[mover]?.add(pocketKind)
        }
        return p
    }

    public func status(_ pos: Position) -> GameStatus {
        if legalMoves(pos).isEmpty {
            return pos.inCheck(pos.sideToMove) ? .checkmate(winner: pos.sideToMove.opposite) : .stalemate
        }
        // No insufficient-material draw in Crazyhouse (reserves can always deliver mate).
        if pos.halfmoveClock >= 200 { return .draw(reason: "No progress") }
        return .ongoing
    }

    public func evaluate(_ pos: Position) -> Int {
        // Pocket pieces are worth a little less than pieces on the board.
        var score = 0
        for p in pos.squares.compactMap({ $0 }) where p.kind != .king {
            score += p.color == .white ? p.kind.value : -p.kind.value
        }
        for (color, pocket) in pos.pockets {
            for (kind, n) in pocket.counts where kind != .king {
                score += (color == .white ? 1 : -1) * (kind.value * 3 / 4) * n
            }
        }
        return score + centralBonus(pos)
    }
}
