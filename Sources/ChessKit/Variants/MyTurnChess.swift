import Foundation

/// My Turn Chess: real-time chess with no alternating turns. Both armies are live at
/// once — either side may move at any moment, and whoever completes a legal move first
/// has it registered. There is no "wait your turn" lock.
///
/// Interpretation (single device, two players sharing one board): turn order is not
/// enforced. Pick up a piece of either colour and move it; the side to move simply
/// follows whichever army you touch. The chess rules themselves are entirely orthodox —
/// moves must be legal (you can't leave your own king in check), and the game ends on
/// **checkmate or stalemate** (and the usual draws) just like normal chess. The only
/// twist is that there is no "wait your turn" lock: either side may move at any moment.
public struct MyTurnChess: ChessVariant {
    public init() {}
    public var name: String { "My Turn Chess" }
    public var blurb: String {
        "Real-time chess — no turns! Both armies move at once; grab any piece and go."
    }
    /// This variant is only ever played in real-time (no turns); it never offers the
    /// turn-based Computer / 2-Players / Watch / Nearby modes.
    public var isRealtimeOnly: Bool { true }

    // MARK: How checks work (player-configurable in Settings)

    /// Checks are awkward when there are no turns, so the player picks how they behave.
    public enum WinRule: String, CaseIterable, Sendable, Identifiable {
        /// Orthodox: only legal moves (no moving into check); checkmate or stalemate ends it.
        case checkmate
        /// Blitz: check is ignored; you win by capturing the enemy king outright.
        case kingCapture
        public var id: String { rawValue }
        public var title: String { self == .checkmate ? "Checkmate" : "King Capture" }
        public var detail: String {
            switch self {
            case .checkmate:   return "Orthodox rules — you can't move into check, and checkmate or stalemate ends the game."
            case .kingCapture: return "Blitz rules — check is ignored; just grab the enemy king to win."
            }
        }
    }
    /// UserDefaults key shared by the Settings UI and the rule lookup below.
    public static let winRuleKey = "ck.myturn.winRule"
    /// The current rule (defaults to orthodox Checkmate). Read live so a change in Settings
    /// applies to the next position evaluated.
    public static var winRule: WinRule {
        UserDefaults.standard.string(forKey: winRuleKey).flatMap(WinRule.init(rawValue:)) ?? .checkmate
    }

    /// Moves offered to the side to move. In Checkmate mode these are orthodox legal moves;
    /// in King-Capture mode they're pseudo-legal (you may ignore check and take the king).
    public func legalMoves(_ pos: Position) -> [Move] {
        Self.winRule == .kingCapture ? StandardRules.pseudoMoves(pos)
                                     : StandardChess.legalStandardMoves(pos)
    }

    public func make(_ move: Move, in pos: Position) -> Position {
        StandardRules.apply(move, to: pos).position
    }

    /// Checkmate mode ends on checkmate / stalemate / the usual draws; King-Capture mode ends
    /// only when a king is taken (or the 50-move clock runs out).
    public func status(_ pos: Position) -> GameStatus {
        guard Self.winRule == .kingCapture else {
            return StandardChess.standardStatus(pos, variant: self)
        }
        if pos.kingSquare(.white) == nil { return .variantWin(winner: .black, reason: "White king captured") }
        if pos.kingSquare(.black) == nil { return .variantWin(winner: .white, reason: "Black king captured") }
        if pos.halfmoveClock >= 100 { return .draw(reason: "50-move rule") }
        return .ongoing
    }

    /// Material plus a nudge to crowd the enemy king (the only target that ends the game).
    public func evaluate(_ pos: Position) -> Int {
        var score = pos.material() + centralBonus(pos)
        if let wk = pos.kingSquare(.white), let bk = pos.kingSquare(.black) {
            score -= kingPressure(pos, king: bk, by: .white)   // pressuring Black's king favours White
            score += kingPressure(pos, king: wk, by: .black)
        }
        return score
    }

    /// Rough count of `attacker`'s pieces lurking near `king` — reward hunting the king down.
    private func kingPressure(_ pos: Position, king: Int, by attacker: PieceColor) -> Int {
        let f = king % 8, r = king / 8
        var n = 0
        for df in -2...2 { for dr in -2...2 {
            let ff = f + df, rr = r + dr
            guard ff >= 0, ff < 8, rr >= 0, rr < 8 else { continue }
            if let p = pos.squares[rr * 8 + ff], p.color == attacker, p.kind != .king { n += 4 }
        } }
        return n
    }
}
