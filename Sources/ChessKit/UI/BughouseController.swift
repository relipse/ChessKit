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

public enum SeatPlayer: Equatable, Codable, Sendable { case human, computer(Difficulty) }

/// One move in the global Bughouse order (which board + the move) — replaying the log
/// reconstructs both boards including all passed pieces.
public struct BughouseLogEntry: Codable, Sendable { public var board: Int; public var move: Move }

/// A serialisable Bughouse match.
public struct BughouseSave: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var date: Date
    public var seats: [SeatPlayer]          // indexed by BughouseSeat.rawValue (0–3)
    public var log: [BughouseLogEntry]
    public init(id: UUID = UUID(), name: String, date: Date, seats: [SeatPlayer], log: [BughouseLogEntry]) {
        self.id = id; self.name = name; self.date = date; self.seats = seats; self.log = log
    }
}

/// On-disk store for Bughouse matches (autosave + named slots).
@MainActor
public final class BughouseStore: ObservableObject {
    @Published public private(set) var autosave: BughouseSave?
    @Published public private(set) var slots: [BughouseSave] = []
    private let url: URL
    private struct Disk: Codable { var autosave: BughouseSave?; var slots: [BughouseSave] }

    public init(filename: String = "bughouse_games.json") {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(filename)
        if let d = try? Data(contentsOf: url), let disk = try? JSONDecoder().decode(Disk.self, from: d) {
            autosave = disk.autosave; slots = disk.slots
        }
    }
    private func persist() {
        if let d = try? JSONEncoder().encode(Disk(autosave: autosave, slots: slots)) { try? d.write(to: url) }
    }
    public func setAutosave(_ s: BughouseSave?) { autosave = s; persist() }
    public func save(_ s: BughouseSave) {
        if let i = slots.firstIndex(where: { $0.id == s.id }) { slots[i] = s } else { slots.insert(s, at: 0) }
        slots.sort { $0.date > $1.date }; persist()
    }
    public func delete(_ s: BughouseSave) { slots.removeAll { $0.id == s.id }; persist() }
}

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
    @Published public private(set) var moveLog: [BughouseLogEntry] = []
    /// Recent partner chat ("You: +N", "Partner: sit", …) for the comms log.
    @Published public private(set) var chat: [String] = []
    /// Standing instruction a computer partner is following, keyed by seat.
    private var botRequest: [BughouseSeat: PartnerCommand] = [:]

    /// Bughouse comms — quick things you tell your partner.
    public enum PartnerCommand: Equatable, Sendable {
        case need(PieceKind)   // "+N" — send me this piece
        case sit               // stop trading / slow down
        case go                // trade & attack, feed me pieces
        case mate              // I'm going for mate
        public var label: String {
            switch self {
            case .need(let k): return "+\(String(k.rawValue))"
            case .sit: return "Sit"; case .go: return "Go"; case .mate: return "Mate!"
            }
        }
    }

    public let seats: [BughouseSeat: SeatPlayer]
    public let store: BughouseStore?
    private var gameID = UUID()
    private var replaying = false
    private let rules = CrazyhouseChess()
    private var aiTasks: [Task<Void, Never>?] = [nil, nil]

    private static func freshBoards() -> [Board] {
        var start = Position.standard
        start.pockets = [.white: Pocket(), .black: Pocket()]
        return [Board(pos: start), Board(pos: start)]
    }

    public init(seats: [BughouseSeat: SeatPlayer], store: BughouseStore? = nil, restore: BughouseSave? = nil) {
        if let restore {
            var s: [BughouseSeat: SeatPlayer] = [:]
            for seat in BughouseSeat.allCases {
                s[seat] = seat.rawValue < restore.seats.count ? restore.seats[seat.rawValue] : .computer(.medium)
            }
            self.seats = s
            self.gameID = restore.id
        } else {
            self.seats = seats
        }
        self.store = store
        self.boards = BughouseController.freshBoards()
        if let restore { replayLog(restore.log) }
        for b in 0..<2 { maybeStartAI(b) }
    }

    public func newGame() {
        aiTasks.forEach { $0?.cancel() }
        gameID = UUID()
        boards = BughouseController.freshBoards()
        moveLog = []; status = .ongoing; thinking = [false, false]
        store?.setAutosave(nil)
        for b in 0..<2 { maybeStartAI(b) }
    }

    private func replayLog(_ log: [BughouseLogEntry]) {
        replaying = true
        for entry in log { apply(entry.board, entry.move) }
        replaying = false
    }

    // MARK: Save

    public func toSave(name: String) -> BughouseSave {
        let arr = BughouseSeat.allCases.map { seats[$0] ?? .computer(.medium) }
        return BughouseSave(id: gameID, name: name, date: Date(), seats: arr, log: moveLog)
    }
    public func saveSlot(name: String) { store?.save(toSave(name: name)) }
    private func autosave() {
        guard let store else { return }
        if status.isOver || moveLog.isEmpty { store.setAutosave(nil) }
        else { store.setAutosave(toSave(name: "Autosave")) }
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
        moveLog.append(BughouseLogEntry(board: b, move: move))
        updateStatus()
        if !replaying {
            autosave()
            if !status.isOver { maybeStartAI(b) }   // next side on this board
        }
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
        let req = botRequest[seat(board: b, color: snapshot.sideToMove)]
        let engine = SearchEngine(variant: rules, difficulty: diff)
        let rules = self.rules
        aiTasks[b] = Task { [weak self] in
            async let best: Move? = Task.detached(priority: .userInitiated) {
                BughouseController.pickMove(rules: rules, engine: engine, pos: snapshot, request: req)
            }.value
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self else { return }
            guard self.boards[b].pos == snapshot, !self.status.isOver else { self.thinking[b] = false; return }
            self.thinking[b] = false
            if let m = await best { self.apply(b, m) }
        }
    }

    /// Choose a bot move, biased by any standing partner command (kept light & fun, not optimal).
    nonisolated private static func pickMove(rules: CrazyhouseChess, engine: SearchEngine,
                                             pos: Position, request: PartnerCommand?) -> Move? {
        let legal = rules.legalMoves(pos)
        guard !legal.isEmpty else { return nil }
        func isCap(_ m: Move) -> Bool { !m.isDrop && pos.squares[m.to] != nil }
        func bestOf(_ subset: [Move]) -> Move? {
            let perspective = pos.sideToMove == .white ? 1 : -1
            return subset.max { a, b in
                perspective * rules.evaluate(rules.make(a, in: pos)) < perspective * rules.evaluate(rules.make(b, in: pos))
            }
        }
        switch request {
        case .need(let kind):
            // Try to capture that piece (to pass it to the partner) — pick the safest such capture.
            let caps = legal.filter { !$0.isDrop && pos.squares[$0.to]?.kind == kind }
            if let m = bestOf(caps) { return m }
        case .go:
            let caps = legal.filter(isCap)
            if let m = bestOf(caps), !caps.isEmpty { return m }
        case .sit:
            // Avoid feeding the opponent: prefer a strong quiet move.
            let quiet = legal.filter { !isCap($0) }
            if let m = bestOf(quiet), !quiet.isEmpty { return m }
        case .mate, .none:
            break
        }
        return engine.bestMove(in: pos)
    }

    // MARK: Partner comms

    public func partner(of seat: BughouseSeat) -> BughouseSeat {
        switch seat {
        case .b1White: return .b2Black; case .b2Black: return .b1White
        case .b1Black: return .b2White; case .b2White: return .b1Black
        }
    }
    /// The human "driving" — first human seat (used to aim comms and focus the layout).
    public var primaryHumanSeat: BughouseSeat? {
        BughouseSeat.allCases.first { seats[$0] == .human }
    }
    public var myBoard: Int { primaryHumanSeat?.board ?? 0 }
    public var hasHuman: Bool { primaryHumanSeat != nil }

    /// A predefined bughouse phrase — public chat, optionally nudging a computer partner.
    public struct Phrase: Identifiable, Sendable {
        public let id: Int
        public let text: String
        let bias: PartnerCommand?
    }

    /// The bughouse-lingo quick phrases everyone can say.
    public static let phrases: [Phrase] = [
        .init(id: 0, text: "Send me a pawn!",   bias: .need(.pawn)),
        .init(id: 1, text: "Send me a knight!", bias: .need(.knight)),
        .init(id: 2, text: "Send me a bishop!", bias: .need(.bishop)),
        .init(id: 3, text: "Send me a rook!",   bias: .need(.rook)),
        .init(id: 4, text: "Send me a queen!",  bias: .need(.queen)),
        .init(id: 5, text: "Sit! Don't trade.", bias: .sit),
        .init(id: 6, text: "Go! Feed me pieces.", bias: .go),
        .init(id: 7, text: "Trade everything!", bias: .go),
        .init(id: 8, text: "Hold — I'm getting mated!", bias: .sit),
        .init(id: 9, text: "Mate coming — stall!", bias: .sit),
        .init(id: 10, text: "Need a piece for mate!", bias: nil),
        .init(id: 11, text: "Watch the back rank!", bias: nil),
        .init(id: 12, text: "Nice!", bias: nil),
        .init(id: 13, text: "Hurry!", bias: nil),
    ]

    /// Say a phrase out loud (everyone sees it). If it carries a request and the speaker's
    /// partner is a computer, it nudges that bot's play.
    public func say(_ phrase: Phrase, from seat: BughouseSeat? = nil) {
        let speaker = seat ?? primaryHumanSeat ?? .b1White
        let who = (speaker == primaryHumanSeat) ? "You" : speaker.label
        chat.append("\(who): \(phrase.text)")
        if chat.count > 30 { chat.removeFirst(chat.count - 30) }
        if let bias = phrase.bias {
            let mate = partner(of: speaker)
            if case .computer = seats[mate] { botRequest[mate] = bias }
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
