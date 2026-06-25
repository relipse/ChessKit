import Foundation

/// Difficulty presets that map to search depth and a touch of randomness.
public enum Difficulty: String, CaseIterable, Identifiable, Codable, Sendable {
    case easy, medium, hard

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// Nominal search depth (plies). Drop-heavy variants get clamped in the engine.
    public var depth: Int {
        switch self {
        case .easy: return 2
        case .medium: return 3
        case .hard: return 4
        }
    }
    /// Probability of *not* picking the very best move (keeps easy levels beatable / human).
    public var blunderChance: Double {
        switch self {
        case .easy: return 0.35
        case .medium: return 0.10
        case .hard: return 0.0
        }
    }
}

/// A variant-agnostic negamax search with alpha-beta pruning. Works for any `ChessVariant`
/// purely through `legalMoves` / `make` / `status` / `evaluate`.
public struct SearchEngine: Sendable {
    public let variant: ChessVariant
    public var difficulty: Difficulty

    public init(variant: ChessVariant, difficulty: Difficulty = .medium) {
        self.variant = variant
        self.difficulty = difficulty
    }

    private static let mateScore = 1_000_000

    /// Choose a move for the side to move in `pos`. `rng` is injectable for deterministic tests.
    public func bestMove(in pos: Position, rng: inout some RandomNumberGenerator) -> Move? {
        let moves = orderedMoves(pos)
        guard !moves.isEmpty else { return nil }

        // Crazyhouse explodes the branching factor with drops — keep it shallow.
        let depth = variant.usesPockets ? min(difficulty.depth, 2) : difficulty.depth
        let perspective = pos.sideToMove == .white ? 1 : -1

        var scored: [(move: Move, score: Int)] = []
        var alpha = -SearchEngine.mateScore * 2
        let beta = SearchEngine.mateScore * 2
        for move in moves {
            let next = variant.make(move, in: pos)
            let score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -alpha,
                                 perspective: -perspective)
            scored.append((move, score))
            alpha = max(alpha, score)
        }
        scored.sort { $0.score > $1.score }

        // Difficulty: sometimes pick a near-best move instead of the best.
        if difficulty.blunderChance > 0, scored.count > 1,
           Double.random(in: 0..<1, using: &rng) < difficulty.blunderChance {
            let topK = min(scored.count, difficulty == .easy ? 4 : 2)
            return scored[Int.random(in: 0..<topK, using: &rng)].move
        }
        // Randomise among equally-best moves so play isn't deterministic.
        let best = scored[0].score
        let ties = scored.filter { $0.score == best }
        return ties[Int.random(in: 0..<ties.count, using: &rng)].move
    }

    /// Convenience using the system RNG.
    public func bestMove(in pos: Position) -> Move? {
        var rng = SystemRandomNumberGenerator()
        return bestMove(in: pos, rng: &rng)
    }

    private func negamax(_ pos: Position, depth: Int, alpha: Int, beta: Int, perspective: Int) -> Int {
        let status = variant.status(pos)
        switch status {
        case .checkmate(let winner):
            // Side to move is mated → very bad for them. Add depth so faster mates score higher.
            let s = SearchEngine.mateScore - (10 - depth)
            return winner == pos.sideToMove ? s : -s
        case .variantWin(let winner, _):
            let s = SearchEngine.mateScore - (10 - depth)
            return winner == pos.sideToMove ? s : -s
        case .stalemate, .draw:
            return 0
        case .ongoing:
            break
        }
        if depth <= 0 {
            return perspective * variant.evaluate(pos)
        }
        var a = alpha
        var best = -SearchEngine.mateScore * 2
        for move in orderedMoves(pos) {
            let next = variant.make(move, in: pos)
            let score = -negamax(next, depth: depth - 1, alpha: -beta, beta: -a, perspective: -perspective)
            best = max(best, score)
            a = max(a, score)
            if a >= beta { break }   // alpha-beta cutoff
        }
        return best
    }

    /// Captures and promotions first — cheap move ordering that makes alpha-beta bite.
    private func orderedMoves(_ pos: Position) -> [Move] {
        variant.legalMoves(pos).sorted { lhs, rhs in
            moveScore(lhs, pos) > moveScore(rhs, pos)
        }
    }

    private func moveScore(_ move: Move, _ pos: Position) -> Int {
        var s = 0
        if move.isDrop { return 1 }
        if let victim = pos.squares[move.to] { s += 10 * victim.kind.value }
        if move.promotion != nil { s += 800 }
        return s
    }
}
