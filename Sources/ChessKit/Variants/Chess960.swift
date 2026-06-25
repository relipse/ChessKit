import Foundation

/// Fischer Random Chess (Chess960): the back rank is shuffled into one of 960 legal
/// starting setups (bishops on opposite colours, king between the rooks). Rules are
/// otherwise orthodox, with Chess960 castling handled by the core engine.
public struct Chess960: ChessVariant {
    /// Fixed starting position id (0–959), or nil to randomise each new game.
    public var positionID: Int?

    public init(positionID: Int? = nil) { self.positionID = positionID }

    public var name: String { "Fischer Random" }
    public var blurb: String { "Chess960 — a shuffled back rank, then pure chess." }

    public func startPosition() -> Position {
        let id = positionID ?? Int.random(in: 0..<960)
        return Chess960.position(id: id)
    }

    public func legalMoves(_ pos: Position) -> [Move] { StandardChess.legalStandardMoves(pos) }
    public func make(_ move: Move, in pos: Position) -> Position { StandardRules.apply(move, to: pos).position }
    public func status(_ pos: Position) -> GameStatus { StandardChess.standardStatus(pos, variant: self) }

    // MARK: Position generation

    /// The back-rank arrangement for a given Chess960 id, using the standard
    /// (Scharnagl) numbering so ids are stable and reproducible.
    public static func backRank(id: Int) -> [PieceKind] {
        var rank = [PieceKind?](repeating: nil, count: 8)
        var n = max(0, min(959, id))

        // 1. Light-squared bishop on one of files 1,3,5,7 (0-indexed odd).
        let lightFiles = [1, 3, 5, 7]
        rank[lightFiles[n % 4]] = .bishop; n /= 4
        // 2. Dark-squared bishop on one of files 0,2,4,6.
        let darkFiles = [0, 2, 4, 6]
        rank[darkFiles[n % 4]] = .bishop; n /= 4
        // 3. Queen on one of the remaining 6 empty squares.
        let queenSlot = n % 6; n /= 6
        placeInNthEmpty(&rank, queenSlot, .queen)
        // 4. Two knights into the remaining 5 squares per the KRN table (10 combinations).
        let knightTable: [(Int, Int)] = [(0,1),(0,2),(0,3),(0,4),(1,2),(1,3),(1,4),(2,3),(2,4),(3,4)]
        let (a, b) = knightTable[n % 10]
        placeInNthEmpty(&rank, a, .knight)
        placeInNthEmpty(&rank, b - 1, .knight)   // b shifts left by one after first knight placed
        // 5. Remaining three squares get R K R, left to right.
        let rest = rank.enumerated().compactMap { $0.element == nil ? $0.offset : nil }
        rank[rest[0]] = .rook; rank[rest[1]] = .king; rank[rest[2]] = .rook
        return rank.map { $0! }
    }

    private static func placeInNthEmpty(_ rank: inout [PieceKind?], _ nth: Int, _ kind: PieceKind) {
        var count = 0
        for i in 0..<8 where rank[i] == nil {
            if count == nth { rank[i] = kind; return }
            count += 1
        }
    }

    public static func position(id: Int) -> Position {
        let back = backRank(id: id)
        var sq = [Piece?](repeating: nil, count: 64)
        for f in 0..<8 {
            sq[f] = Piece(color: .white, kind: back[f])
            sq[8 + f] = Piece(color: .white, kind: .pawn)
            sq[48 + f] = Piece(color: .black, kind: .pawn)
            sq[56 + f] = Piece(color: .black, kind: back[f])
        }
        var pos = Position(squares: sq)
        // Record the rook files for castling (queenside rook = left of king, kingside = right).
        let kingFile = back.firstIndex(of: .king)!
        let rookFiles = back.enumerated().compactMap { $0.element == .rook ? $0.offset : nil }
        let qFile = rookFiles.first { $0 < kingFile } ?? 0
        let kFile = rookFiles.first { $0 > kingFile } ?? 7
        pos.castleRookFile = ["K": kFile, "Q": qFile, "k": kFile, "q": qFile]
        return pos
    }
}
