import Foundation

public extension StandardRules {
    /// Standard Algebraic Notation for `move` in `pos` (the position *before* the move).
    /// Crazyhouse drops render as "N@f3". Castling as "O-O" / "O-O-O".
    static func san(for move: Move, in pos: Position, legalMoves: [Move]? = nil) -> String {
        if let kind = move.dropKind {
            return "\(String(kind.rawValue))@\(squareName(move.to))"
        }
        guard let piece = pos.squares[move.from] else { return move.description }

        if let side = move.castle {
            return side == .king ? "O-O" : "O-O-O"
        }

        let isCapture = pos.squares[move.to] != nil
            || (piece.kind == .pawn && move.to == pos.enPassant)

        var out = ""
        if piece.kind == .pawn {
            if isCapture { out += String(UnicodeScalar(UInt8(97 + move.from % 8))) + "x" }
            out += squareName(move.to)
            if let promo = move.promotion { out += "=" + String(promo.rawValue) }
            return out
        }

        out += String(piece.kind.rawValue)
        out += disambiguation(for: move, piece: piece, in: pos, legalMoves: legalMoves)
        if isCapture { out += "x" }
        out += squareName(move.to)
        return out
    }

    /// The minimal file/rank disambiguator needed when another same-kind piece can reach `to`.
    private static func disambiguation(for move: Move, piece: Piece, in pos: Position,
                                       legalMoves: [Move]?) -> String {
        let moves = legalMoves ?? StandardChess.legalStandardMoves(pos)
        let rivals = moves.filter { other in
            !other.isDrop && other.to == move.to && other.from != move.from
                && pos.squares[other.from]?.kind == piece.kind
        }
        guard !rivals.isEmpty else { return "" }
        let sameFile = rivals.contains { $0.from % 8 == move.from % 8 }
        let sameRank = rivals.contains { $0.from / 8 == move.from / 8 }
        if !sameFile { return String(UnicodeScalar(UInt8(97 + move.from % 8))) }   // file disambiguates
        if !sameRank { return String(move.from / 8 + 1) }                          // rank disambiguates
        return squareName(move.from)                                              // need both
    }
}
