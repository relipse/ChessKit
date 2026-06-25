import Foundation

/// Shared standard-chess mechanics reused by every variant: pseudo-move generation
/// and the low-level board mutation. Variants layer their own rules on top
/// (drops, explosions, hidden information, …).
public enum StandardRules {

    /// Result of applying a move's mechanics, before any variant-specific effects.
    public struct Applied {
        public var position: Position
        /// The piece removed by the move (normal capture or en-passant), if any.
        public var captured: Piece?
        /// The square the captured piece stood on (differs from `to` on en passant).
        public var capturedSquare: Int?
    }

    // MARK: Pseudo-move generation

    /// All pseudo-legal board moves for the side to move (own-king safety NOT yet checked).
    public static func pseudoMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        var moves: [Move] = []
        for s in 0..<64 {
            guard let p = pos.squares[s], p.color == me else { continue }
            let promoRank = me == .white ? 7 : 0
            for t in pos.pseudoTargets(from: s) {
                if let q = pos.squares[t], q.color == me { continue }   // own piece blocks
                if p.kind == .pawn, t / 8 == promoRank {
                    for promo in [PieceKind.queen, .rook, .bishop, .knight] {
                        moves.append(Move(from: s, to: t, promotion: promo))
                    }
                } else {
                    moves.append(Move(from: s, to: t))
                }
            }
        }
        moves += castlingMoves(pos)
        return moves
    }

    /// Castling moves available by rights + empty squares + not moving through check.
    /// Generalised for Chess960: the king ends on g/c and the rook on f/d regardless of
    /// their starting files; the squares the king travels must be empty (bar the castling
    /// rook) and unattacked.
    static func castlingMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        let r = me == .white ? 0 : 7
        guard let kingFrom = pos.kingSquare(me), kingFrom / 8 == r else { return [] }
        guard !pos.isSquareAttacked(kingFrom, by: me.opposite) else { return [] }
        var out: [Move] = []
        let (kRight, qRight): (Character, Character) = me == .white ? ("K", "Q") : ("k", "q")

        func tryCastle(_ right: Character, side: CastleSide) {
            guard pos.castling.contains(right), let rookFile = pos.castleRookFile[right] else { return }
            let rookFrom = r * 8 + rookFile
            guard pos.squares[rookFrom]?.kind == .rook, pos.squares[rookFrom]?.color == me else { return }
            let kingTo = r * 8 + (side == .king ? 6 : 2)
            let rookTo = r * 8 + (side == .king ? 5 : 3)
            // Squares that must be empty: the king's path and the rook's path,
            // excluding the king and rook's own starting squares.
            let exempt: Set<Int> = [kingFrom, rookFrom]
            for sq in squaresBetween(kingFrom, kingTo) + squaresBetween(rookFrom, rookTo) + [kingTo, rookTo] {
                if !exempt.contains(sq), pos.squares[sq] != nil { return }
            }
            // The king may not pass through or land on an attacked square.
            for sq in squaresBetween(kingFrom, kingTo) + [kingTo] {
                if pos.isSquareAttacked(sq, by: me.opposite) { return }
            }
            out.append(Move(from: kingFrom, to: kingTo, castle: side))
        }
        tryCastle(kRight, side: .king)
        tryCastle(qRight, side: .queen)
        return out
    }

    /// Squares strictly between `a` and `b` on the same rank (exclusive of both ends).
    static func squaresBetween(_ a: Int, _ b: Int) -> [Int] {
        guard a / 8 == b / 8, a != b else { return [] }
        let r = a / 8
        let lo = min(a % 8, b % 8), hi = max(a % 8, b % 8)
        return (lo + 1..<hi).map { r * 8 + $0 }
    }

    /// True if `move` is a castling move.
    public static func isCastle(_ move: Move, in pos: Position) -> Bool {
        move.castle != nil
    }

    // MARK: Low-level mutation

    /// Apply a board move's mechanics (castling, en passant, promotion, rights, clocks).
    /// Does not validate legality. Drops are not handled here.
    public static func apply(_ move: Move, to pos: Position) -> Applied {
        var p = pos
        let me = p.sideToMove
        guard !move.isDrop, var mover = p.squares[move.from] else {
            return Applied(position: p, captured: nil, capturedSquare: nil)
        }

        var captured: Piece?
        var capturedSquare: Int?

        if let side = move.castle {
            let r = me == .white ? 0 : 7
            let right: Character = me == .white ? (side == .king ? "K" : "Q") : (side == .king ? "k" : "q")
            let rookFile = pos.castleRookFile[right] ?? (side == .king ? 7 : 0)
            let rookFrom = r * 8 + rookFile
            let kingTo = r * 8 + (side == .king ? 6 : 2)
            let rookTo = r * 8 + (side == .king ? 5 : 3)
            p.squares[move.from] = nil
            p.squares[rookFrom] = nil
            p.squares[kingTo] = Piece(color: me, kind: .king)
            p.squares[rookTo] = Piece(color: me, kind: .rook)
            removeCastlingRights(&p, color: me)
            p.enPassant = nil
            p.halfmoveClock += 1
            advanceSide(&p)
            return Applied(position: p, captured: nil, capturedSquare: nil)
        }

        // En passant capture.
        if mover.kind == .pawn, move.to == p.enPassant, p.squares[move.to] == nil {
            let capSq = (move.from / 8) * 8 + (move.to % 8)
            captured = p.squares[capSq]
            capturedSquare = capSq
            p.squares[capSq] = nil
        } else if let q = p.squares[move.to] {
            captured = q
            capturedSquare = move.to
        }

        // New en-passant target on a double push.
        let newEP: Int?
        if mover.kind == .pawn, abs(move.to / 8 - move.from / 8) == 2 {
            newEP = (move.from / 8 + (move.to / 8 - move.from / 8) / 2) * 8 + (move.from % 8)
        } else { newEP = nil }

        let wasPromoted = p.promoted.contains(move.from)
        p.squares[move.from] = nil
        p.promoted.remove(move.from)
        if let pr = move.promotion {
            mover = Piece(color: mover.color, kind: pr)
            p.promoted.insert(move.to)   // tracked for Crazyhouse; harmless otherwise
        } else if wasPromoted {
            p.promoted.insert(move.to)
        } else {
            p.promoted.remove(move.to)
        }
        p.squares[move.to] = mover

        updateCastlingRights(&p, from: move.from, to: move.to, piece: mover)
        p.enPassant = newEP
        if mover.kind == .pawn || captured != nil { p.halfmoveClock = 0 } else { p.halfmoveClock += 1 }
        advanceSide(&p)
        return Applied(position: p, captured: captured, capturedSquare: capturedSquare)
    }

    static func advanceSide(_ p: inout Position) {
        if p.sideToMove == .black { p.fullmove += 1 }
        p.sideToMove = p.sideToMove.opposite
    }

    static func removeCastlingRights(_ p: inout Position, color: PieceColor) {
        if color == .white { p.castling.remove("K"); p.castling.remove("Q") }
        else { p.castling.remove("k"); p.castling.remove("q") }
    }

    static func updateCastlingRights(_ p: inout Position, from: Int, to: Int, piece: Piece) {
        if piece.kind == .king { removeCastlingRights(&p, color: piece.color) }
        // A move from/to a castling rook's home square forfeits that right (rook moved or captured).
        func clear(_ sq: Int) {
            for (right, file) in p.castleRookFile {
                let rank = (right == "K" || right == "Q") ? 0 : 7
                if sq == rank * 8 + file { p.castling.remove(right) }
            }
        }
        clear(from); clear(to)
    }
}
