import Foundation

// MARK: - Basic chess types

public enum PieceColor: String, Equatable, Hashable, Codable, Sendable {
    case white, black
    public var opposite: PieceColor { self == .white ? .black : .white }
}

public enum PieceKind: Character, Equatable, Hashable, Codable, CaseIterable, Sendable {
    case pawn = "P", knight = "N", bishop = "B", rook = "R", queen = "Q", king = "K"

    /// Centipawn material value used by the search evaluator.
    public var value: Int {
        switch self {
        case .pawn: return 100
        case .knight: return 320
        case .bishop: return 330
        case .rook: return 500
        case .queen: return 900
        case .king: return 20000
        }
    }
}

public struct Piece: Equatable, Hashable, Codable, Sendable {
    public var color: PieceColor
    public var kind: PieceKind
    public init(color: PieceColor, kind: PieceKind) {
        self.color = color
        self.kind = kind
    }
}

// MARK: - Square helpers

/// File a..h -> 0..7
public func fileIndex(_ c: Character) -> Int? {
    guard c >= "a", c <= "h", let a = c.asciiValue, let base = Character("a").asciiValue else { return nil }
    return Int(a - base)
}
/// Rank '1'..'8' -> 0..7
public func rankIndex(_ c: Character) -> Int? {
    guard c >= "1", c <= "8", let a = c.asciiValue, let base = Character("1").asciiValue else { return nil }
    return Int(a - base)
}
/// 0-based square index (rank*8+file) -> algebraic, e.g. 0 -> "a1".
public func squareName(_ sq: Int) -> String {
    guard (0..<64).contains(sq) else { return "??" }
    let f = sq % 8, r = sq / 8
    return "\(Character(UnicodeScalar(UInt8(97 + f))))\(r + 1)"
}

/// A pocket of capturable pieces a side may drop (Crazyhouse). Indexed by kind.
public struct Pocket: Equatable, Hashable, Codable, Sendable {
    public var counts: [PieceKind: Int] = [:]
    public init() {}
    public var isEmpty: Bool { counts.values.allSatisfy { $0 == 0 } }
    public mutating func add(_ k: PieceKind) { counts[k, default: 0] += 1 }
    public mutating func remove(_ k: PieceKind) { counts[k, default: 0] = max(0, (counts[k] ?? 0) - 1) }
    public func count(_ k: PieceKind) -> Int { counts[k] ?? 0 }
    /// Droppable kinds in display order (no king).
    public var kindsAvailable: [PieceKind] {
        [.pawn, .knight, .bishop, .rook, .queen].filter { count($0) > 0 }
    }
}

// MARK: - Position

/// A chess position with enough state to play any of the supported variants.
/// Squares are indexed `rank * 8 + file`, with file a..h = 0..7 and rank 1..8 = 0..7.
public struct Position: Equatable, Hashable, Sendable {
    public var squares: [Piece?]
    public var sideToMove: PieceColor = .white
    public var castling: Set<Character> = ["K", "Q", "k", "q"]
    public var enPassant: Int? = nil
    public var halfmoveClock: Int = 0
    public var fullmove: Int = 1

    /// Files (0–7) of the rooks that may castle, keyed by right ("K","Q","k","q").
    /// Standard chess uses h/a (7/0); Chess960 sets these per starting position.
    public var castleRookFile: [Character: Int] = ["K": 7, "Q": 0, "k": 7, "q": 0]

    // Variant state (empty / unused for standard chess).
    /// Captured pieces available to drop, keyed by the owner who may drop them (Crazyhouse).
    public var pockets: [PieceColor: Pocket] = [.white: Pocket(), .black: Pocket()]
    /// Squares currently holding a promoted pawn — on capture they re-enter the pocket as pawns (Crazyhouse).
    public var promoted: Set<Int> = []

    public init(squares: [Piece?], sideToMove: PieceColor = .white,
                castling: Set<Character> = ["K", "Q", "k", "q"], enPassant: Int? = nil,
                halfmoveClock: Int = 0, fullmove: Int = 1) {
        self.squares = squares
        self.sideToMove = sideToMove
        self.castling = castling
        self.enPassant = enPassant
        self.halfmoveClock = halfmoveClock
        self.fullmove = fullmove
    }

    /// The standard chess starting position.
    public static var standard: Position {
        var sq = [Piece?](repeating: nil, count: 64)
        let back: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for f in 0..<8 {
            sq[f] = Piece(color: .white, kind: back[f])
            sq[8 + f] = Piece(color: .white, kind: .pawn)
            sq[48 + f] = Piece(color: .black, kind: .pawn)
            sq[56 + f] = Piece(color: .black, kind: back[f])
        }
        return Position(squares: sq)
    }

    /// Parse a FEN string.
    public init?(fen: String) {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let board = parts.first else { return nil }
        let ranks = board.split(separator: "/")
        guard ranks.count == 8 else { return nil }
        var sq = [Piece?](repeating: nil, count: 64)
        for (i, rankStr) in ranks.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in rankStr {
                if ch.isNumber, let d = ch.wholeNumberValue {
                    file += d
                } else {
                    guard file < 8 else { return nil }
                    let color: PieceColor = ch.isUppercase ? .white : .black
                    guard let kind = PieceKind(rawValue: Character(ch.uppercased())) else { return nil }
                    sq[rank * 8 + file] = Piece(color: color, kind: kind)
                    file += 1
                }
            }
        }
        self.squares = sq
        self.sideToMove = (parts.count > 1 && parts[1] == "b") ? .black : .white
        self.castling = parts.count > 2 ? Set(parts[2].filter { "KQkq".contains($0) }) : []
        if parts.count > 3, parts[3] != "-", parts[3].count == 2 {
            let chars = Array(parts[3])
            if let ff = fileIndex(chars[0]), let rr = rankIndex(chars[1]) { self.enPassant = rr * 8 + ff }
        }
        self.halfmoveClock = parts.count > 4 ? (Int(parts[4]) ?? 0) : 0
        self.fullmove = parts.count > 5 ? (Int(parts[5]) ?? 1) : 1
        self.pockets = [.white: Pocket(), .black: Pocket()]
    }

    // MARK: Queries

    public func kingSquare(_ color: PieceColor) -> Int? {
        squares.firstIndex { $0?.kind == .king && $0?.color == color }
    }

    /// Pseudo-legal destination squares reachable by the piece on `sq` (ignores leaving own king in check).
    public func pseudoTargets(from sq: Int) -> [Int] {
        guard let p = squares[sq] else { return [] }
        let f = sq % 8, r = sq / 8
        var out: [Int] = []
        func add(_ ff: Int, _ rr: Int) {
            if ff >= 0, ff < 8, rr >= 0, rr < 8 { out.append(rr * 8 + ff) }
        }
        switch p.kind {
        case .knight:
            for (df, dr) in [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)] {
                add(f + df, r + dr)
            }
        case .king:
            for df in -1...1 { for dr in -1...1 where !(df == 0 && dr == 0) { add(f + df, r + dr) } }
        case .bishop, .rook, .queen:
            var dirs: [(Int, Int)] = []
            if p.kind != .rook { dirs += [(1, 1), (1, -1), (-1, 1), (-1, -1)] }
            if p.kind != .bishop { dirs += [(1, 0), (-1, 0), (0, 1), (0, -1)] }
            for (df, dr) in dirs {
                var ff = f + df, rr = r + dr
                while ff >= 0, ff < 8, rr >= 0, rr < 8 {
                    let t = rr * 8 + ff
                    out.append(t)
                    if squares[t] != nil { break }
                    ff += df; rr += dr
                }
            }
        case .pawn:
            let dir = p.color == .white ? 1 : -1
            let startRank = p.color == .white ? 1 : 6
            if r + dir >= 0, r + dir < 8 {
                let one = (r + dir) * 8 + f
                if squares[one] == nil {
                    out.append(one)
                    let two = (r + 2 * dir) * 8 + f
                    if r == startRank, squares[two] == nil { out.append(two) }
                }
                for df in [-1, 1] {
                    let cf = f + df, cr = r + dir
                    if cf >= 0, cf < 8 {
                        let t = cr * 8 + cf
                        if let q = squares[t], q.color != p.color { out.append(t) }
                        else if t == enPassant { out.append(t) }
                    }
                }
            }
        }
        return out
    }

    /// Whether `target` is attacked by any piece of `color`.
    /// `kingAttacks` lets a variant (Atomic) disable the enemy king as an attacker,
    /// since an atomic king can never capture.
    public func isSquareAttacked(_ target: Int, by color: PieceColor, kingAttacks: Bool = true) -> Bool {
        let tf = target % 8, tr = target / 8
        let pawnSrcDir = color == .white ? -1 : 1
        for df in [-1, 1] {
            let ff = tf + df, rr = tr + pawnSrcDir
            if ff >= 0, ff < 8, rr >= 0, rr < 8,
               let p = squares[rr * 8 + ff], p.color == color, p.kind == .pawn { return true }
        }
        for (df, dr) in [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)] {
            let ff = tf + df, rr = tr + dr
            if ff >= 0, ff < 8, rr >= 0, rr < 8,
               let p = squares[rr * 8 + ff], p.color == color, p.kind == .knight { return true }
        }
        if kingAttacks {
            for df in -1...1 { for dr in -1...1 where !(df == 0 && dr == 0) {
                let ff = tf + df, rr = tr + dr
                if ff >= 0, ff < 8, rr >= 0, rr < 8,
                   let p = squares[rr * 8 + ff], p.color == color, p.kind == .king { return true }
            } }
        }
        for (df, dr) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
            var ff = tf + df, rr = tr + dr
            while ff >= 0, ff < 8, rr >= 0, rr < 8 {
                if let p = squares[rr * 8 + ff] {
                    if p.color == color, (p.kind == .bishop || p.kind == .queen) { return true }
                    break
                }
                ff += df; rr += dr
            }
        }
        for (df, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            var ff = tf + df, rr = tr + dr
            while ff >= 0, ff < 8, rr >= 0, rr < 8 {
                if let p = squares[rr * 8 + ff] {
                    if p.color == color, (p.kind == .rook || p.kind == .queen) { return true }
                    break
                }
                ff += df; rr += dr
            }
        }
        return false
    }

    /// Convenience: is `color`'s king currently attacked (standard check test)?
    public func inCheck(_ color: PieceColor, kingAttacks: Bool = true) -> Bool {
        guard let ks = kingSquare(color) else { return false }
        return isSquareAttacked(ks, by: color.opposite, kingAttacks: kingAttacks)
    }

    /// Material balance (white − black) in centipawns, excluding kings, including pockets.
    public func material() -> Int {
        var score = 0
        for p in squares.compactMap({ $0 }) where p.kind != .king {
            score += p.color == .white ? p.kind.value : -p.kind.value
        }
        for (color, pocket) in pockets {
            for (kind, n) in pocket.counts where kind != .king {
                score += (color == .white ? 1 : -1) * kind.value * n
            }
        }
        return score
    }

    /// FEN serialisation (board + side + castling + ep + clocks). Pockets are not encoded.
    public func fen() -> String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let p = squares[rank * 8 + file] {
                    if empty > 0 { row += String(empty); empty = 0 }
                    let c = String(p.kind.rawValue)
                    row += p.color == .white ? c : c.lowercased()
                } else { empty += 1 }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        let board = rows.joined(separator: "/")
        let side = sideToMove == .white ? "w" : "b"
        let castle = castling.isEmpty ? "-" : "KQkq".filter { castling.contains($0) }
        let ep = enPassant.map(squareName) ?? "-"
        return "\(board) \(side) \(castle) \(ep) \(halfmoveClock) \(fullmove)"
    }
}
