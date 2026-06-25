import SwiftUI

/// The four seats in a Bughouse match. Board 1 and Board 2 each have a White and Black seat.
/// Partners (a team) play OPPOSITE colours on OPPOSITE boards:
///   Team A = Board1-White + Board2-Black   ·   Team B = Board1-Black + Board2-White
public enum BughouseSeat: Int, CaseIterable, Identifiable, Sendable {
    case b1White, b1Black, b2White, b2Black
    public var id: Int { rawValue }
    public var board: Int { (self == .b1White || self == .b1Black) ? 0 : 1 }
    public var color: PieceColor { (self == .b1White || self == .b2White) ? .white : .black }
    public var team: Int { (self == .b1White || self == .b2Black) ? 0 : 1 }
    public var label: String {
        switch self {
        case .b1White: return "Board 1 · White"; case .b1Black: return "Board 1 · Black"
        case .b2White: return "Board 2 · White"; case .b2Black: return "Board 2 · Black"
        }
    }
}

public enum SeatPlayer: Equatable, Sendable { case human, computer(Difficulty) }

public enum BughouseStatus: Equatable, Sendable {
    case ongoing
    case win(team: Int, reason: String)
    case draw(String)
    var isOver: Bool { if case .ongoing = self { return false }; return true }
}

/// Drives a single-device Bughouse match across two boards. Each board plays by Crazyhouse
/// rules, but captured pieces are passed to the **partner's** reserve on the other board.
@MainActor
public final class BughouseController: ObservableObject {
    /// Per-board interaction + render state.
    public struct Board {
        public var pos: Position
        public var selected: Int?
        public var targets: Set<Int> = []
        public var pocketSel: PieceKind?
        public var lastMove: (from: Int, to: Int)?
    }

    @Published public var boards: [Board]
    @Published public private(set) var status: BughouseStatus = .ongoing
    @Published public private(set) var thinking: [Bool] = [false, false]

    public let seats: [BughouseSeat: SeatPlayer]
    private let rules = CrazyhouseChess()
    private var aiTasks: [Task<Void, Never>?] = [nil, nil]

    public init(seats: [BughouseSeat: SeatPlayer]) {
        self.seats = seats
        var start = Position.standard
        start.pockets = [.white: Pocket(), .black: Pocket()]
        boards = [Board(pos: start), Board(pos: start)]
        for b in 0..<2 { maybeStartAI(b) }
    }

    public func newGame() {
        aiTasks.forEach { $0?.cancel() }
        var start = Position.standard
        start.pockets = [.white: Pocket(), .black: Pocket()]
        boards = [Board(pos: start), Board(pos: start)]
        status = .ongoing; thinking = [false, false]
        for b in 0..<2 { maybeStartAI(b) }
    }

    // MARK: Seat / turn helpers

    public func seat(board: Int, color: PieceColor) -> BughouseSeat {
        switch (board, color) {
        case (0, .white): return .b1White; case (0, .black): return .b1Black
        case (1, .white): return .b2White; default: return .b2Black
        }
    }
    private func player(_ board: Int, _ color: PieceColor) -> SeatPlayer {
        seats[seat(board: board, color: color)] ?? .computer(.medium)
    }
    public func isHumanToMove(_ board: Int) -> Bool {
        guard !status.isOver else { return false }
        return player(board, boards[board].pos.sideToMove) == .human
    }

    // MARK: Human interaction (board index 0/1)

    public func tap(board b: Int, _ sq: Int) {
        guard isHumanToMove(b) else { return }
        var bd = boards[b]
        if let kind = bd.pocketSel {
            if bd.targets.contains(sq) { commit(b, Move(drop: kind, to: sq)); return }
            bd.selected = nil; bd.targets = []; bd.pocketSel = nil; boards[b] = bd; return
        }
        if let from = bd.selected {
            if sq == from { bd.selected = nil; bd.targets = []; boards[b] = bd; return }
            if bd.targets.contains(sq) { commit(b, resolve(b, from, sq)); return }
        }
        if let p = bd.pos.squares[sq], p.color == bd.pos.sideToMove {
            bd.selected = sq; bd.pocketSel = nil
            bd.targets = Set(rules.legalMoves(from: sq, in: bd.pos).map(\.to))
        } else { bd.selected = nil; bd.targets = [] }
        boards[b] = bd
    }

    public func move(board b: Int, from: Int, to: Int) {
        guard isHumanToMove(b) else { return }
        if boards[b].selected != from, let p = boards[b].pos.squares[from], p.color == boards[b].pos.sideToMove {
            tap(board: b, from)
        }
        guard boards[b].selected == from else { return }
        tap(board: b, to)
    }

    public func selectPocket(board b: Int, _ kind: PieceKind) {
        guard isHumanToMove(b), (boards[b].pos.pockets[boards[b].pos.sideToMove]?.count(kind) ?? 0) > 0 else { return }
        var bd = boards[b]; bd.selected = nil
        if bd.pocketSel == kind { bd.pocketSel = nil; bd.targets = [] }
        else { bd.pocketSel = kind; bd.targets = Set(rules.legalDrops(of: kind, in: bd.pos).map(\.to)) }
        boards[b] = bd
    }

    public func dropPiece(board b: Int, _ kind: PieceKind, to sq: Int) {
        guard isHumanToMove(b) else { return }
        if rules.legalDrops(of: kind, in: boards[b].pos).contains(where: { $0.to == sq }) {
            commit(b, Move(drop: kind, to: sq))
        }
    }

    /// Auto-queen for promotions to keep Bughouse one-tap.
    private func resolve(_ b: Int, _ from: Int, _ to: Int) -> Move {
        if let p = boards[b].pos.squares[from], p.kind == .pawn, to / 8 == 7 || to / 8 == 0 {
            return Move(from: from, to: to, promotion: .queen)
        }
        let legal = rules.legalMoves(boards[b].pos)
        return legal.first { $0.from == from && $0.to == to } ?? Move(from: from, to: to)
    }

    // MARK: Applying moves + passing

    private func commit(_ b: Int, _ rawMove: Move) {
        let legal = rules.legalMoves(boards[b].pos)
        let move: Move
        if rawMove.isDrop {
            guard legal.contains(rawMove) else { clearSel(b); return }
            move = rawMove
        } else {
            guard let m = legal.first(where: { $0.from == rawMove.from && $0.to == rawMove.to && $0.promotion == rawMove.promotion }) else { clearSel(b); return }
            move = m
        }
        apply(b, move)
    }

    private func apply(_ b: Int, _ move: Move) {
        var bd = boards[b]
        let mover = bd.pos.sideToMove
        if move.isDrop {
            bd.pos.squares[move.to] = Piece(color: mover, kind: move.dropKind!)
            bd.pos.pockets[mover]?.remove(move.dropKind!)
            bd.pos.promoted.remove(move.to)
            bd.pos.enPassant = nil
            StandardRules.advanceSide(&bd.pos)
            bd.lastMove = nil
        } else {
            let before = bd.pos
            let applied = StandardRules.apply(move, to: before)
            bd.pos = applied.position
            bd.lastMove = (move.from, move.to)
            if let cap = applied.captured, let csq = applied.capturedSquare {
                // Pass the captured piece to the PARTNER's reserve on the OTHER board
                // (a promoted pawn reverts to a pawn).
                let kind: PieceKind = before.promoted.contains(csq) ? .pawn : cap.kind
                boards[1 - b].pos.pockets[cap.color]?.add(kind)
            }
        }
        bd.selected = nil; bd.targets = []; bd.pocketSel = nil
        boards[b] = bd
        updateStatus()
        if !status.isOver { maybeStartAI(b) }   // next side on this board
    }

    private func clearSel(_ b: Int) {
        var bd = boards[b]; bd.selected = nil; bd.targets = []; bd.pocketSel = nil; boards[b] = bd
    }

    private func updateStatus() {
        for b in 0..<2 {
            let st = rules.status(boards[b].pos)
            if case .checkmate(let winner) = st {
                let winningSeat = seat(board: b, color: winner)
                status = .win(team: winningSeat.team, reason: "Checkmate on Board \(b + 1)")
                aiTasks.forEach { $0?.cancel() }
                return
            }
            if case .stalemate = st { status = .draw("Stalemate on Board \(b + 1)"); return }
        }
    }

    // MARK: AI

    private func maybeStartAI(_ b: Int) {
        guard !status.isOver else { return }
        guard case .computer(let diff) = player(b, boards[b].pos.sideToMove) else { return }
        thinking[b] = true
        aiTasks[b]?.cancel()
        let snapshot = boards[b].pos
        let engine = SearchEngine(variant: rules, difficulty: diff)
        aiTasks[b] = Task { [weak self] in
            async let best: Move? = Task.detached(priority: .userInitiated) { engine.bestMove(in: snapshot) }.value
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self else { return }
            guard self.boards[b].pos == snapshot, !self.status.isOver else { self.thinking[b] = false; return }
            self.thinking[b] = false
            if let m = await best { self.apply(b, m) }
        }
    }

    public var resultText: String {
        switch status {
        case .ongoing: return ""
        case .win(let team, let why): return "Team \(team == 0 ? "A" : "B") wins — \(why)"
        case .draw(let why): return "Draw — \(why)"
        }
    }
}
