import Foundation

/// Which way a king is castling.
public enum CastleSide: String, Equatable, Hashable, Codable, Sendable { case king, queen }

/// A single move. Board moves use `from`/`to`; Crazyhouse drops set `dropKind` with `from == -1`.
/// Castling carries an explicit `castle` side (needed for Chess960's variable rook files).
public struct Move: Equatable, Hashable, Codable, Sendable {
    public var from: Int            // -1 for a drop
    public var to: Int              // king's destination square for a castle
    public var promotion: PieceKind?
    public var dropKind: PieceKind? // non-nil for a Crazyhouse drop
    public var castle: CastleSide?  // non-nil for a castling move

    public init(from: Int, to: Int, promotion: PieceKind? = nil, castle: CastleSide? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
        self.dropKind = nil
        self.castle = castle
    }

    /// A Crazyhouse drop of `kind` onto `square`.
    public init(drop kind: PieceKind, to square: Int) {
        self.from = -1
        self.to = square
        self.promotion = nil
        self.dropKind = kind
        self.castle = nil
    }

    public var isDrop: Bool { dropKind != nil }

    /// Coordinate (UCI-ish) string, e.g. "e2e4", "e7e8q", "N@f3".
    public var description: String {
        if let k = dropKind { return "\(k.rawValue)@\(squareName(to))" }
        let promo = promotion.map { String($0.rawValue).lowercased() } ?? ""
        return "\(squareName(from))\(squareName(to))\(promo)"
    }
}

/// Outcome of a position under a given variant's rules.
public enum GameStatus: Equatable, Sendable {
    case ongoing
    case checkmate(winner: PieceColor)
    case stalemate
    case draw(reason: String)
    /// A variant-specific win not expressible as checkmate (e.g. Atomic king explosion).
    case variantWin(winner: PieceColor, reason: String)

    public var isOver: Bool { if case .ongoing = self { return false }; return true }
    public var winner: PieceColor? {
        switch self {
        case .checkmate(let w), .variantWin(let w, _): return w
        default: return nil
        }
    }
}
