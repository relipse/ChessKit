import SwiftUI

/// Deterministic RNG so screenshot positions are stable across runs.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state
    }
}

/// Builds a lively mid-game position for App Store screenshots: plays a fixed number of
/// plausible moves (favouring captures + development) so the board looks like a real game.
public enum DemoGame {
    public static func savedGame(for variant: ChessVariant, plies: Int = 12, seed: UInt64 = 7) -> SavedGame {
        let start = variant.startPosition()
        var pos = start
        var rng = SeededRNG(seed: seed)
        var moves: [Move] = []
        for _ in 0..<plies {
            let legal = variant.legalMoves(pos)
            guard !legal.isEmpty else { break }
            let captures = legal.filter { isCapture($0, pos) }
            let develop = legal.filter { m -> Bool in
                guard !m.isDrop, let p = pos.squares[m.from] else { return false }
                return p.kind != .pawn && p.kind != .king
            }
            let wantCapture = !captures.isEmpty && Bool.random(using: &rng)
            let wantDevelop = !develop.isEmpty && Bool.random(using: &rng)
            let pool: [Move] = wantCapture ? captures : (wantDevelop ? develop : legal)
            let move = pool[Int.random(in: 0..<pool.count, using: &rng)]
            moves.append(move)
            pos = variant.make(move, in: pos)
            if variant.status(pos).isOver { break }
        }
        var rookFiles: [String: Int] = [:]
        for (k, v) in start.castleRookFile { rookFiles[String(k)] = v }
        return SavedGame(name: "Demo", date: .init(timeIntervalSince1970: 0), variantName: variant.name,
                         startFEN: start.fen(), rookFiles: rookFiles, moves: moves,
                         humanColor: .white, difficulty: .medium, mode: .computer)
    }

    private static func isCapture(_ m: Move, _ pos: Position) -> Bool {
        guard !m.isDrop else { return false }
        return pos.squares[m.to] != nil
            || (pos.squares[m.from]?.kind == .pawn && m.to == pos.enPassant)
    }
}
