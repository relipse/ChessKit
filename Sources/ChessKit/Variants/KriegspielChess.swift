import Foundation

/// Kriegspiel: the rules are orthodox chess, but each player sees only their own
/// pieces. A referee adjudicates attempted moves and announces captures, checks and
/// available pawn tries — never revealing where the enemy actually is.
public struct KriegspielChess: ChessVariant {
    public init() {}
    public var name: String { "Kriegspiel" }
    public var blurb: String { "Fog of war (also called Kriegspiel) — you see only your own army; a referee announces the rest." }
    public var hidesOpponentPieces: Bool { true }

    public func legalMoves(_ pos: Position) -> [Move] {
        StandardChess.legalStandardMoves(pos)
    }
    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }
    public func status(_ pos: Position) -> GameStatus {
        StandardChess.standardStatus(pos, variant: self)
    }
}

/// The umpire's verdict on a single attempted move — what a real Kriegspiel referee
/// would call out to the room.
public struct KriegspielReferee {

    public enum CheckDirection: String, Sendable {
        case rank = "on the rank"
        case file = "on the file"
        case longDiagonal = "on the long diagonal"
        case shortDiagonal = "on the short diagonal"
        case knight = "by a knight"
    }

    public struct Verdict: Sendable {
        public var legal: Bool
        public var capture: Bool
        public var captureSquare: Int?
        public var checks: [CheckDirection]
        /// Number of legal pawn captures the mover currently has ("Any?" → "two", etc.).
        public var pawnTries: Int
        /// A spoken summary, e.g. "Capture on e5. Check on the file."
        public var announcement: String
    }

    public init() {}

    /// Is `move` legal in `pos`? (Used to validate a blind player's attempt.)
    public func isLegal(_ move: Move, in pos: Position) -> Bool {
        StandardChess.legalStandardMoves(pos).contains(move)
    }

    /// Adjudicate an attempted move. If illegal, returns a verdict with `legal == false`
    /// and the position is unchanged (the player tries again).
    public func adjudicate(_ move: Move, in pos: Position) -> Verdict {
        guard isLegal(move, in: pos) else {
            return Verdict(legal: false, capture: false, captureSquare: nil, checks: [],
                           pawnTries: 0, announcement: "Illegal — try again.")
        }
        let applied = StandardRules.apply(move, to: pos)
        let next = applied.position
        let mover = pos.sideToMove
        let opp = mover.opposite

        let capture = applied.captured != nil
        var parts: [String] = []
        if capture, let sq = applied.capturedSquare { parts.append("Capture on \(squareName(sq)).") }

        var checks: [CheckDirection] = []
        if let ks = next.kingSquare(opp), next.isSquareAttacked(ks, by: mover) {
            checks = checkDirections(kingSquare: ks, attacker: mover, in: next)
            for c in checks { parts.append("Check \(c.rawValue).") }
        }

        // Pawn tries available to the *opponent* on their upcoming move.
        let tries = pawnTryCount(in: next)
        if parts.isEmpty { parts.append(capture ? "" : "No.") }

        return Verdict(legal: true, capture: capture, captureSquare: applied.capturedSquare,
                       checks: checks, pawnTries: tries,
                       announcement: parts.joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }

    /// From which directions the king on `kingSquare` is being checked.
    func checkDirections(kingSquare ks: Int, attacker: PieceColor, in pos: Position) -> [CheckDirection] {
        var dirs: Set<CheckDirection> = []
        let kf = ks % 8, kr = ks / 8
        // Knights.
        for (df, dr) in [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)] {
            let ff = kf + df, rr = kr + dr
            if ff >= 0, ff < 8, rr >= 0, rr < 8,
               let p = pos.squares[rr * 8 + ff], p.color == attacker, p.kind == .knight { dirs.insert(.knight) }
        }
        // Sliding & pawn checks by ray.
        let rays: [(Int, Int, Bool)] = [   // (df, dr, isDiagonal)
            (1, 0, false), (-1, 0, false), (0, 1, false), (0, -1, false),
            (1, 1, true), (1, -1, true), (-1, 1, true), (-1, -1, true)
        ]
        for (df, dr, diag) in rays {
            var ff = kf + df, rr = kr + dr
            var steps = 0
            while ff >= 0, ff < 8, rr >= 0, rr < 8 {
                steps += 1
                if let p = pos.squares[rr * 8 + ff] {
                    if p.color == attacker {
                        let hits: Bool
                        if diag {
                            hits = p.kind == .bishop || p.kind == .queen
                                || (steps == 1 && p.kind == .pawn && pawnGivesCheck(attacker, df: df, dr: dr))
                        } else {
                            hits = p.kind == .rook || p.kind == .queen
                        }
                        if hits {
                            if !diag { dirs.insert(df != 0 ? .rank : .file) }
                            else { dirs.insert(isLongDiagonal(ks) ? .longDiagonal : .shortDiagonal) }
                        }
                    }
                    break
                }
                ff += df; rr += dr
            }
        }
        return Array(dirs)
    }

    private func pawnGivesCheck(_ attacker: PieceColor, df: Int, dr: Int) -> Bool {
        // A white pawn checks diagonally upward toward black king (dr from king's view is downward).
        attacker == .white ? dr == -1 : dr == 1
    }

    /// "Long" if the checking diagonal is one of the two principal (a1-h8 / h1-a8) diagonals.
    private func isLongDiagonal(_ ks: Int) -> Bool {
        let f = ks % 8, r = ks / 8
        return f == r || f + r == 7
    }

    /// How many pawn captures the side to move currently has ("Any?" announcement).
    func pawnTryCount(in pos: Position) -> Int {
        let me = pos.sideToMove
        var n = 0
        for s in 0..<64 {
            guard let p = pos.squares[s], p.color == me, p.kind == .pawn else { continue }
            let dir = me == .white ? 1 : -1
            let r = s / 8, f = s % 8
            for df in [-1, 1] {
                let cf = f + df, cr = r + dir
                guard cf >= 0, cf < 8, cr >= 0, cr < 8 else { continue }
                let t = cr * 8 + cf
                if let q = pos.squares[t], q.color != me { n += 1 }
                else if t == pos.enPassant { n += 1 }
            }
        }
        return n
    }
}
