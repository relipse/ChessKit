import Foundation

/// Shapeshifter Chess (a "wizard's chess" idea): a non-pawn piece moves according to the
/// **file it currently stands on**, not its identity — and so its powers change as it moves.
///   • a/h files → move like a Rook
///   • b/g files → move like a Knight
///   • c/f files → move like a Bishop
///   • d file    → move like a Queen
///   • e file    → move like a King (one step)
/// Pawns are normal. The king is still the royal piece you must checkmate. No castling.
public struct ShapeshifterChess: ChessVariant {
    public init() {}
    public var name: String { "Shapeshifter" }
    public var blurb: String {
        "Every piece moves by the file it's on — d-file moves like a queen, e-file like a king, c/f like bishops, b/g like knights, a/h like rooks."
    }

    /// The movement type a non-pawn piece takes on a given file.
    public static func fileKind(_ file: Int) -> PieceKind {
        switch file {
        case 0, 7: return .rook
        case 1, 6: return .knight
        case 2, 5: return .bishop
        case 3:    return .queen
        default:   return .king   // e-file (and any unexpected) → king-style step
        }
    }

    private func moveKind(at sq: Int, piece: Piece) -> PieceKind {
        piece.kind == .pawn ? .pawn : ShapeshifterChess.fileKind(sq % 8)
    }

    public func legalMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        return pseudoMoves(pos).filter { move in
            let next = make(move, in: pos)
            guard let ks = next.kingSquare(me) else { return false }
            return !isAttacked(ks, by: me.opposite, in: next)
        }
    }

    func pseudoMoves(_ pos: Position) -> [Move] {
        let me = pos.sideToMove
        var moves: [Move] = []
        for s in 0..<64 {
            guard let p = pos.squares[s], p.color == me else { continue }
            let promoRank = me == .white ? 7 : 0
            let targets = p.kind == .pawn
                ? pos.pseudoTargets(from: s)
                : pos.pseudoTargets(from: s, asKind: ShapeshifterChess.fileKind(s % 8), color: me)
            for t in targets {
                if let q = pos.squares[t], q.color == me { continue }
                if p.kind == .pawn, t / 8 == promoRank {
                    for promo in [PieceKind.queen, .rook, .bishop, .knight] {
                        moves.append(Move(from: s, to: t, promotion: promo))
                    }
                } else {
                    moves.append(Move(from: s, to: t))
                }
            }
        }
        return moves   // no castling in Shapeshifter
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    /// File-aware attack detection (pawns attack diagonally; everyone else by their file kind).
    func isAttacked(_ target: Int, by color: PieceColor, in pos: Position) -> Bool {
        for s in 0..<64 {
            guard let p = pos.squares[s], p.color == color else { continue }
            if p.kind == .pawn {
                let dir = color == .white ? 1 : -1
                let r = s / 8, f = s % 8
                for df in [-1, 1] where f + df >= 0 && f + df < 8 && r + dir >= 0 && r + dir < 8 {
                    if (r + dir) * 8 + (f + df) == target { return true }
                }
            } else if pos.pseudoTargets(from: s, asKind: ShapeshifterChess.fileKind(s % 8), color: color).contains(target) {
                return true
            }
        }
        return false
    }

    public func status(_ pos: Position) -> GameStatus {
        if legalMoves(pos).isEmpty {
            let me = pos.sideToMove
            if let ks = pos.kingSquare(me), isAttacked(ks, by: me.opposite, in: pos) {
                return .checkmate(winner: me.opposite)
            }
            return .stalemate
        }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    public func evaluate(_ pos: Position) -> Int {
        var score = 0
        for sq in 0..<64 {
            guard let p = pos.squares[sq], p.kind != .king else { continue }
            let value = p.kind == .pawn ? 100 : ShapeshifterChess.movementValue(sq % 8)
            score += p.color == .white ? value : -value
        }
        return score + centralBonus(pos)
    }

    /// Worth of a non-pawn piece by the powers its file grants (a "king-mover" is a strong minor).
    static func movementValue(_ file: Int) -> Int {
        switch fileKind(file) {
        case .rook: return 500
        case .knight: return 320
        case .bishop: return 330
        case .queen: return 900
        case .king: return 280   // commoner: moves one step in any direction
        default: return 300
        }
    }
}
