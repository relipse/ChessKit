import Foundation

/// Atomic: every capture detonates. The capturing piece, the captured piece, and all
/// non-pawn pieces on the 8 surrounding squares are removed. You win by blowing up the
/// enemy king; you may never blow up your own. Kings cannot capture.
public struct AtomicChess: ChessVariant {
    public init() {}
    public var name: String { "Atomic" }
    public var blurb: String { "Captures explode — destroy the enemy king or be destroyed." }

    public func legalMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        var out: [Move] = []
        for move in StandardRules.pseudoMoves(pos) {
            // Kings can never capture (it would explode themselves).
            if let p = pos.squares[move.from], p.kind == .king,
               let q = pos.squares[move.to], q.color != me { continue }
            let next = make(move, in: pos)
            // Mover's king must survive the blast.
            guard next.kingSquare(me) != nil else { continue }
            // Exploding the enemy king wins immediately, even out of "check".
            if next.kingSquare(me.opposite) == nil { out.append(move); continue }
            // Otherwise the mover may not be left in check (enemy king never attacks).
            if let ks = next.kingSquare(me), next.isSquareAttacked(ks, by: me.opposite, kingAttacks: false) {
                continue
            }
            out.append(move)
        }
        return out
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        let mover = pos.sideToMove
        let applied = StandardRules.apply(move, to: pos)
        var p = applied.position
        if applied.captured != nil {
            explode(&p, center: move.to, mover: mover)
        }
        return p
    }

    /// Detonate at `center`: remove the capturing piece and every non-pawn on the ring.
    private func explode(_ p: inout Position, center: Int, mover: PieceColor) {
        p.squares[center] = nil
        p.promoted.remove(center)
        let f = center % 8, r = center / 8
        for df in -1...1 { for dr in -1...1 where !(df == 0 && dr == 0) {
            let ff = f + df, rr = r + dr
            guard ff >= 0, ff < 8, rr >= 0, rr < 8 else { continue }
            let sq = rr * 8 + ff
            if let piece = p.squares[sq], piece.kind != .pawn {
                p.squares[sq] = nil
                p.promoted.remove(sq)
            }
        } }
        // Castling rights lost for any rook that no longer sits on its home square.
        for (sq, ch) in [(0, Character("Q")), (7, "K"), (56, "q"), (63, "k")] {
            if p.squares[sq]?.kind != .rook { p.castling.remove(ch) }
        }
        if p.kingSquare(.white) == nil { p.castling.remove("K"); p.castling.remove("Q") }
        if p.kingSquare(.black) == nil { p.castling.remove("k"); p.castling.remove("q") }
    }

    public func status(_ pos: Position) -> GameStatus {
        if pos.kingSquare(.white) == nil { return .variantWin(winner: .black, reason: "White king exploded") }
        if pos.kingSquare(.black) == nil { return .variantWin(winner: .white, reason: "Black king exploded") }
        if legalMoves(pos).isEmpty {
            if pos.inCheck(pos.sideToMove, kingAttacks: false) {
                return .checkmate(winner: pos.sideToMove.opposite)
            }
            return .stalemate
        }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    public func evaluate(_ pos: Position) -> Int {
        var score = pos.material() + centralBonus(pos)
        // Reward keeping pieces clustered near the enemy king (explosion threats).
        if let wk = pos.kingSquare(.white), let bk = pos.kingSquare(.black) {
            score -= kingExposure(pos, king: bk, by: .white) // attacking black king is good for white
            score += kingExposure(pos, king: wk, by: .black)
        }
        return score
    }

    /// Count of `attacker`'s pieces adjacent-ish to `king`'s neighbourhood (rough threat term).
    private func kingExposure(_ pos: Position, king: Int, by attacker: PieceColor) -> Int {
        let f = king % 8, r = king / 8
        var n = 0
        for df in -2...2 { for dr in -2...2 {
            let ff = f + df, rr = r + dr
            guard ff >= 0, ff < 8, rr >= 0, rr < 8 else { continue }
            if let p = pos.squares[rr * 8 + ff], p.color == attacker, p.kind != .king { n += 3 }
        } }
        return n
    }
}

/// The built-in variants, in menu order.
public enum Variants {
    public static let all: [ChessVariant] = [
        StandardChess(), KriegspielChess(), CrazyhouseChess(), AtomicChess(), Chess960()
    ]
}
