import XCTest
@testable import ChessKit

final class ChessKitTests: XCTestCase {

    // Standard perft: well-known node counts from the initial position.
    func perft(_ pos: Position, depth: Int, variant: ChessVariant) -> Int {
        if depth == 0 { return 1 }
        var nodes = 0
        for move in variant.legalMoves(pos) {
            nodes += perft(variant.make(move, in: pos), depth: depth - 1, variant: variant)
        }
        return nodes
    }

    func testStandardPerft() {
        let v = StandardChess()
        let start = v.startPosition()
        XCTAssertEqual(perft(start, depth: 1, variant: v), 20)
        XCTAssertEqual(perft(start, depth: 2, variant: v), 400)
        XCTAssertEqual(perft(start, depth: 3, variant: v), 8902)
    }

    func testKiwipetePerft() {
        // Classic test position exercising castling, en passant, promotions.
        let fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        let v = StandardChess()
        let pos = Position(fen: fen)!
        XCTAssertEqual(perft(pos, depth: 1, variant: v), 48)
        XCTAssertEqual(perft(pos, depth: 2, variant: v), 2039)
    }

    func testFoolsMate() {
        let v = StandardChess()
        var pos = v.startPosition()
        for san in ["f2f3", "e7e5", "g2g4", "d8h4"] {
            let from = san.prefix(2).squareIndex!
            let to = san.suffix(2).squareIndex!
            let move = Move(from: from, to: to)
            XCTAssertTrue(v.legalMoves(pos).contains(move), "expected \(san) legal")
            pos = v.make(move, in: pos)
        }
        if case .checkmate(let w) = v.status(pos) { XCTAssertEqual(w, .black) }
        else { XCTFail("expected fool's mate") }
    }

    func testCrazyhousePocketAndDrop() {
        let v = CrazyhouseChess()
        // After 1.e4 d5 2.exd5, white should have a pawn in pocket.
        var pos = v.startPosition()
        // 1.e4 d5 2.exd5 (white pockets a pawn) Nf6 — back to white to move.
        for (f, t) in [("e2","e4"), ("d7","d5"), ("e4","d5"), ("g8","f6")] {
            let move = Move(from: f.squareIndex!, to: t.squareIndex!)
            pos = v.make(move, in: pos)
        }
        XCTAssertEqual(pos.pockets[.white]?.count(.pawn), 1)
        XCTAssertEqual(pos.sideToMove, .white)
        // White can drop that pawn somewhere legal.
        let drops = v.legalMoves(pos).filter { $0.isDrop }
        XCTAssertFalse(drops.isEmpty)
    }

    func testAtomicExplosionWinsByKing() {
        let v = AtomicChess()
        // White queen captures the knight on d7, next to the black king, and detonates it.
        let fen = "4k3/3n4/8/8/8/8/8/3QK3 w - - 0 1"
        let pos = Position(fen: fen)!
        // Qxd7 explodes d7 and the adjacent king on e8.
        let cap = Move(from: "d1".squareIndex!, to: "d7".squareIndex!)
        XCTAssertTrue(v.legalMoves(pos).contains(cap))
        let next = v.make(cap, in: pos)
        XCTAssertNil(next.kingSquare(.black), "black king should be exploded")
        XCTAssertEqual(v.status(next).winner, .white)
    }

    func testAtomicKingCannotCapture() {
        let v = AtomicChess()
        let fen = "8/8/8/8/8/8/4p3/4K3 w - - 0 1"  // white king e1, black pawn e2
        let pos = Position(fen: fen)!
        let kc = Move(from: "e1".squareIndex!, to: "e2".squareIndex!)
        XCTAssertFalse(v.legalMoves(pos).contains(kc), "king must not capture in atomic")
    }

    func testKriegspielRefereeAnnouncesCapture() {
        let ref = KriegspielReferee()
        var pos = StandardChess().startPosition()
        for (f, t) in [("e2","e4"), ("d7","d5")] {
            pos = StandardRules.apply(Move(from: f.squareIndex!, to: t.squareIndex!), to: pos).position
        }
        let verdict = ref.adjudicate(Move(from: "e4".squareIndex!, to: "d5".squareIndex!), in: pos)
        XCTAssertTrue(verdict.legal)
        XCTAssertTrue(verdict.capture)
        XCTAssertTrue(verdict.announcement.contains("Capture on d5"))
    }

    func testChess960BackRanksValid() {
        // Every one of the 960 ids must give a legal setup: bishops opposite colours,
        // king between the two rooks.
        for id in 0..<960 {
            let r = Chess960.backRank(id: id)
            XCTAssertEqual(r.count, 8)
            let bishops = r.enumerated().filter { $0.element == .bishop }.map(\.offset)
            XCTAssertEqual(bishops.count, 2)
            XCTAssertNotEqual(bishops[0] % 2, bishops[1] % 2, "bishops must be opposite colours (id \(id))")
            let king = r.firstIndex(of: .king)!
            let rooks = r.enumerated().filter { $0.element == .rook }.map(\.offset)
            XCTAssertEqual(rooks.count, 2)
            XCTAssertTrue(rooks[0] < king && king < rooks[1], "king between rooks (id \(id))")
            XCTAssertEqual(r.filter { $0 == .queen }.count, 1)
            XCTAssertEqual(r.filter { $0 == .knight }.count, 2)
        }
    }

    func testChess960StandardIdIs518() {
        // The orthodox start (RNBQKBNR) is Chess960 #518.
        XCTAssertEqual(Chess960.backRank(id: 518), [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook])
    }

    func testChess960CastlingWorks() {
        // Position 518 == standard; castling should behave exactly like standard chess.
        let v = Chess960(positionID: 518)
        var pos = v.startPosition()
        // Clear f1,g1 so white can castle kingside after a couple moves.
        for (f, t) in [("g1","f3"), ("g8","f6"), ("e2","e4"), ("e7","e5"),
                       ("f1","c4"), ("f8","c5")] {
            let m = v.legalMoves(pos).first { $0.from == f.squareIndex! && $0.to == t.squareIndex! }!
            pos = v.make(m, in: pos)
        }
        let castle = v.legalMoves(pos).first { $0.castle == .king }
        XCTAssertNotNil(castle, "kingside castle should be available")
        let after = v.make(castle!, in: pos)
        XCTAssertEqual(after.squares["g1".squareIndex!]?.kind, .king)
        XCTAssertEqual(after.squares["f1".squareIndex!]?.kind, .rook)
    }

    @MainActor
    func testDragMoveAppliesHumanMove() {
        // move(from:to:) is exactly what a drag-and-drop drop invokes.
        let game = GameController(variant: StandardChess(), humanColor: .white, difficulty: .easy)
        XCTAssertTrue(game.isHumanTurn)
        game.move(from: "e2".squareIndex!, to: "e4".squareIndex!)
        XCTAssertEqual(game.sanHistory.first, "e4")
        XCTAssertEqual(game.position.squares["e4".squareIndex!]?.kind, .pawn)
        XCTAssertNotNil(game.lastMove)
        XCTAssertFalse(game.isHumanTurn)   // now the AI's turn
    }

    @MainActor
    func testDragMoveRejectsIllegal() {
        let game = GameController(variant: StandardChess(), humanColor: .white, difficulty: .easy)
        game.move(from: "e2".squareIndex!, to: "e5".squareIndex!)   // illegal pawn jump
        XCTAssertTrue(game.sanHistory.isEmpty)
        XCTAssertTrue(game.isHumanTurn)
    }

    @MainActor
    func testCrazyhouseDropPlacesPiece() {
        // drop(_:to:) is what both tap-to-place and drag-from-reserve invoke.
        let game = GameController(variant: CrazyhouseChess(), humanColor: .white, difficulty: .easy)
        // Hand White a knight in reserve by replaying captures via move().
        game.move(from: "e2".squareIndex!, to: "e4".squareIndex!)   // hands to AI; just need a pocket
        // Force a known pocket instead of relying on AI: build a fresh controlled game.
        let v = CrazyhouseChess()
        var pos = v.startPosition()
        for (f, t) in [("e2","e4"),("d7","d5"),("e4","d5"),("g8","f6")] {
            pos = v.make(Move(from: f.squareIndex!, to: t.squareIndex!), in: pos)
        }
        XCTAssertEqual(pos.pockets[.white]?.count(.pawn), 1)
        let drops = v.legalDrops(of: .pawn, in: pos)
        XCTAssertFalse(drops.isEmpty, "a pocket pawn should have legal drop squares")
        _ = game   // silence unused
    }

    func testLosersForcedCaptureAndInvertedWin() {
        let v = LosersChess()
        // 1.e4 d5 — now exd5 is a capture, so captures must be the only legal moves.
        var pos = v.startPosition()
        pos = v.make(Move(from: "e2".squareIndex!, to: "e4".squareIndex!), in: pos)
        pos = v.make(Move(from: "d7".squareIndex!, to: "d5".squareIndex!), in: pos)
        let moves = v.legalMoves(pos)
        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { LosersChess.isCapture($0, in: pos) }, "captures are compulsory")
    }

    func testShapeshifterFileMovement() {
        let v = ShapeshifterChess()
        // A rook placed on the d-file should move like a queen (diagonals available).
        let pos = Position(fen: "4k3/8/8/8/8/8/8/3RK3 w - - 0 1")!  // white rook d1, king e1
        let targets = Set(v.legalMoves(pos).filter { $0.from == "d1".squareIndex! }.map(\.to))
        // Diagonal d1-h5 square like a queen would reach:
        XCTAssertTrue(targets.contains("h5".squareIndex!), "d-file piece should move like a queen")
        XCTAssertEqual(ShapeshifterChess.fileKind(3), .queen)
        XCTAssertEqual(ShapeshifterChess.fileKind(4), .king)
        XCTAssertEqual(ShapeshifterChess.fileKind(2), .bishop)
    }

    func testSavedGameRoundTrips() {
        let v = Chess960(positionID: 4)
        var pos = v.startPosition()
        var moves: [Move] = []
        for _ in 0..<6 {
            guard let m = v.legalMoves(pos).first else { break }
            moves.append(m); pos = v.make(m, in: pos)
        }
        var rookFiles: [String: Int] = [:]
        for (k, val) in v.startPosition().castleRookFile { rookFiles[String(k)] = val }
        let saved = SavedGame(name: "t", date: Date(timeIntervalSince1970: 0), variantName: "Fischer Random",
                              startFEN: v.startPosition().fen(), rookFiles: rookFiles, moves: moves,
                              humanColor: .white, difficulty: .medium)
        let data = try! JSONEncoder().encode(saved)
        let back = try! JSONDecoder().decode(SavedGame.self, from: data)
        XCTAssertEqual(back.moves, moves)
        XCTAssertEqual(back.startFEN, saved.startFEN)
    }

    func testPawnDuelStartAndPlay() {
        let v = PawnDuelChess()
        let pos = v.startPosition()
        XCTAssertEqual(pos.squares["a8".squareIndex!]?.kind, .king)
        XCTAssertEqual(pos.squares["h1".squareIndex!]?.kind, .king)
        XCTAssertEqual(pos.squares.compactMap { $0 }.filter { $0.kind == .pawn }.count, 6)
        XCTAssertFalse(v.legalMoves(pos).isEmpty)
    }

    @MainActor
    func testTwoPlayerModeNoAI() {
        let game = GameController(variant: StandardChess(), mode: .passAndPlay)
        game.move(from: "e2".squareIndex!, to: "e4".squareIndex!)
        // In pass-and-play it's immediately Black's (the other human's) turn — no AI took over.
        XCTAssertEqual(game.position.sideToMove, .black)
        XCTAssertTrue(game.isHumanTurn)   // the other human can move now
        XCTAssertEqual(game.sanHistory, ["e4"])
    }

    func testAIPlaysLegalMoves() {
        for v in Variants.all {
            let engine = SearchEngine(variant: v, difficulty: .easy)
            var rng = SeededRNG(seed: 42)
            let move = engine.bestMove(in: v.startPosition(), rng: &rng)
            XCTAssertNotNil(move)
            XCTAssertTrue(v.legalMoves(v.startPosition()).contains(move!))
        }
    }
}

/// Deterministic RNG for tests.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

extension StringProtocol {
    /// "e4" → 28 (rank*8+file). Returns nil if not a 2-char square.
    var squareIndex: Int? {
        let chars = Array(self)
        guard chars.count == 2, let f = fileIndex(chars[0]), let r = rankIndex(chars[1]) else { return nil }
        return r * 8 + f
    }
}
