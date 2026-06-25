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

    /// Black king + a7/b7/c7 pawns (top-left) vs White king + f2/g2/h2 pawns (bottom-right).
    public static let startFEN = "k7/ppp5/8/8/8/8/5PPP/7K w - - 0 1"

    public func startPosition() -> Position { Position(fen: PawnDuelChess.startFEN)! }
    public func legalMoves(_ pos: Position) -> [Move] { StandardChess.legalStandardMoves(pos) }
    public func make(_ move: Move, in pos: Position) -> Position { StandardRules.apply(move, to: pos).position }
    public func status(_ pos: Position) -> GameStatus { StandardChess.standardStatus(pos, variant: self) }
}
