import Foundation

/// The contract every chess variant implements. Implementing this single protocol
/// is enough to get a fully playable game (board, legal-move highlighting, AI
/// opponent, end-of-game detection) from the rest of ChessKit.
public protocol ChessVariant: Sendable {
    /// Display name, e.g. "Crazyhouse".
    var name: String { get }
    /// One-line description shown on menus / about screens.
    var blurb: String { get }
    /// Whether this variant uses Crazyhouse-style piece drops (drives the pocket UI).
    var usesPockets: Bool { get }
    /// Whether opponent pieces are hidden from the player (Kriegspiel fog of war).
    var hidesOpponentPieces: Bool { get }
    /// Whether a capture is compulsory when one is available (Losers/Antichess).
    var forcesCapture: Bool { get }

    /// The starting position.
    func startPosition() -> Position

    /// Every fully-legal move for the side to move in `pos`.
    func legalMoves(_ pos: Position) -> [Move]

    /// Apply a (legal) move and return the resulting position.
    func make(_ move: Move, in pos: Position) -> Position

    /// The status of `pos` (ongoing / checkmate / draw / variant win).
    func status(_ pos: Position) -> GameStatus

    /// Static evaluation in centipawns from White's perspective (used by the AI).
    func evaluate(_ pos: Position) -> Int
}

public extension ChessVariant {
    var blurb: String { "" }
    var usesPockets: Bool { false }
    var hidesOpponentPieces: Bool { false }
    var forcesCapture: Bool { false }

    func startPosition() -> Position { .standard }

    /// Legal moves originating from a given square (for tap-to-move highlighting).
    func legalMoves(from square: Int, in pos: Position) -> [Move] {
        legalMoves(pos).filter { $0.from == square }
    }

    /// Legal drop squares for a pocket piece of `kind` (empty unless the variant uses pockets).
    func legalDrops(of kind: PieceKind, in pos: Position) -> [Move] {
        legalMoves(pos).filter { $0.dropKind == kind }
    }

    /// Default material-based evaluation with a tiny mobility term; good enough for most variants.
    func evaluate(_ pos: Position) -> Int {
        var score = pos.material()
        // Small central / mobility bonus for the side to move's perspective is added in search.
        score += centralBonus(pos)
        return score
    }
}

/// A modest piece-square nudge toward the centre, colour-signed (White +, Black −).
func centralBonus(_ pos: Position) -> Int {
    var s = 0
    let center: Set<Int> = [27, 28, 35, 36]
    let big: Set<Int> = [18, 19, 20, 21, 26, 29, 34, 37, 42, 43, 44, 45]
    for sq in 0..<64 {
        guard let p = pos.squares[sq], p.kind != .king else { continue }
        var b = 0
        if center.contains(sq) { b = 12 } else if big.contains(sq) { b = 5 }
        s += p.color == .white ? b : -b
    }
    return s
}
