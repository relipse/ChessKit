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
    public var baseTime: Double?            // time control (nil → legacy default)
    public var increment: Double?
    public var clocks: [Double]?            // seconds remaining per seat at save time
    public init(id: UUID = UUID(), name: String, date: Date, seats: [SeatPlayer], log: [BughouseLogEntry],
                baseTime: Double? = nil, increment: Double? = nil, clocks: [Double]? = nil) {
        self.id = id; self.name = name; self.date = date; self.seats = seats; self.log = log
        self.baseTime = baseTime; self.increment = increment; self.clocks = clocks
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

/// Transport the controller uses to sync a nearby (multi-device) match.
public protocol BughouseNet: AnyObject {
    func sendMoveToHost(board: Int, move: Move)   // client → host (a move request)
    func broadcastMove(board: Int, move: Move)    // host → all peers (authoritative move)
    func sendChat(_ line: String)                 // table talk to peers
}

/// Where this device sits in a networked match.
public enum BughouseNetRole: Sendable { case offline, host, client }

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

    // Chess clocks (the heart of bughouse — you can stall, sitting on your time for a piece).
    @Published public private(set) var clock: [Double]   // seconds remaining, by seat.rawValue
    public private(set) var baseTime: Double
    public private(set) var increment: Double
    private var tickTask: Task<Void, Never>?

    // Nearby (multi-device) play. offline → all human seats are this device's (same-device hot-seat).
    public var role: BughouseNetRole = .offline
    public weak var net: BughouseNet?
    /// Seats this device's local humans control (host/client only). Empty in offline.
    public var localSeats: Set<BughouseSeat> = []

    private static func freshBoards() -> [Board] {
        var start = Position.standard
        start.pockets = [.white: Pocket(), .black: Pocket()]
        return [Board(pos: start), Board(pos: start)]
    }

    public init(seats: [BughouseSeat: SeatPlayer], store: BughouseStore? = nil, restore: BughouseSave? = nil,
                baseTime: Double = 180, increment: Double = 2) {
        if let restore {
            var s: [BughouseSeat: SeatPlayer] = [:]
            for seat in BughouseSeat.allCases {
                s[seat] = seat.rawValue < restore.seats.count ? restore.seats[seat.rawValue] : .computer(.medium)
            }
            self.seats = s
            self.gameID = restore.id
            self.baseTime = restore.baseTime ?? baseTime
            self.increment = restore.increment ?? increment
        } else {
            self.seats = seats
            self.baseTime = baseTime
            self.increment = increment
        }
        self.store = store
        self.boards = BughouseController.freshBoards()
        self.clock = [Double](repeating: self.baseTime, count: 4)
        if let restore {
            replayLog(restore.log)
            if let c = restore.clocks, c.count == 4 { self.clock = c }
        }
        for b in 0..<2 { maybeStartAI(b) }
        startTicking()
    }

    public func newGame() {
        aiTasks.forEach { $0?.cancel() }; tickTask?.cancel()
        gameID = UUID()
        boards = BughouseController.freshBoards()
        clock = [Double](repeating: baseTime, count: 4)
        moveLog = []; status = .ongoing; thinking = [false, false]
        store?.setAutosave(nil)
        for b in 0..<2 { maybeStartAI(b) }
        startTicking()
    }

    /// Run the clocks: both boards' on-move seats tick down in real time; a flag ends the match.
    public var untimed: Bool { baseTime <= 0 }

    private func startTicking() {
        tickTask?.cancel()
        guard baseTime > 0 else { return }   // "No timer" → clocks never run
        tickTask = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                if self.status.isOver { return }
                let now = Date(); let dt = now.timeIntervalSince(last); last = now
                if self.status.isOver || self.replaying { continue }
                for b in 0..<2 {
                    let s = self.seat(board: b, color: self.boards[b].pos.sideToMove)
                    self.clock[s.rawValue] = max(0, self.clock[s.rawValue] - dt)
                    if self.clock[s.rawValue] <= 0 {
                        self.status = .win(team: 1 - s.team,
                            reason: "Board \(b + 1) \(s.color == .white ? "White" : "Black") flagged")
                        self.aiTasks.forEach { $0?.cancel() }
                    }
                }
            }
        }
    }

    public func clockText(seat: BughouseSeat) -> String {
        if untimed { return "∞" }
        let t = max(0, clock[seat.rawValue])
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func replayLog(_ log: [BughouseLogEntry]) {
        replaying = true
        for entry in log { apply(entry.board, entry.move) }
        replaying = false
    }

    // MARK: Save

    public func toSave(name: String) -> BughouseSave {
        let arr = BughouseSeat.allCases.map { seats[$0] ?? .computer(.medium) }
        return BughouseSave(id: gameID, name: name, date: Date(), seats: arr, log: moveLog,
                            baseTime: baseTime, increment: increment, clocks: clock)
    }
    public func saveSlot(name: String) { store?.save(toSave(name: name)) }
    /// Forget the in-progress match so "Continue" won't offer it.
    public func discardAutosave() { store?.setAutosave(nil) }
    /// Worth offering to save? (has moves and isn't finished)
    public var isResumable: Bool { !moveLog.isEmpty && !status.isOver }
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
        let s = seat(board: board, color: boards[board].pos.sideToMove)
        if role == .offline { return seats[s] == .human }
        return localSeats.contains(s)   // nearby: only the seats this device owns
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
        // A client doesn't own the board state — it asks the host, then applies the host's echo.
        if role == .client { clearSel(b); net?.sendMoveToHost(board: b, move: move); return }
        apply(b, move)
    }

    /// Host applies a validated move that arrived from a peer (then broadcasts it onward).
    public func receivePeerMove(board b: Int, _ move: Move) { guard role == .host else { return }; commit(b, move) }
    /// Client applies the host's authoritative move.
    public func receiveHostMove(board b: Int, _ move: Move) { guard role == .client else { return }; apply(b, move) }

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
        if !replaying { clock[seat(board: b, color: mover).rawValue] += increment }
        updateStatus()
        if !replaying {
            if role == .host { net?.broadcastMove(board: b, move: move) }   // tell the peers
            if role != .client { autosave() }
            if !status.isOver && role != .client { maybeStartAI(b) }   // host/offline run the bots
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
        let talkSeat = seat(board: b, color: snapshot.sideToMove)
        aiTasks[b] = Task { [weak self] in
            async let best: Move? = Task.detached(priority: .userInitiated) {
                BughouseController.pickMove(rules: rules, engine: engine, pos: snapshot, request: req)
            }.value
            // Play at a human-ish pace (not instant), varied so the two boards don't move in lockstep.
            try? await Task.sleep(nanoseconds: UInt64.random(in: 1_200_000_000...2_800_000_000))
            guard let self else { return }
            guard self.boards[b].pos == snapshot, !self.status.isOver else { self.thinking[b] = false; return }
            self.thinking[b] = false
            if let m = await best {
                self.apply(b, m)
                if Int.random(in: 0..<100) < 22 { self.botTalk(seat: talkSeat) }   // coach the partner
            }
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

    /// A bot calls out to its partner to coordinate — ask for a piece, tell them to sit when in
    /// danger, or go when pressing. (Sets the partner's bias if the partner is also a computer.)
    private func botTalk(seat: BughouseSeat) {
        guard !status.isOver else { return }
        let pos = boards[seat.board].pos
        let phrase: Phrase
        if pos.inCheck(seat.color) {
            phrase = BughouseController.phrases.first { $0.bias == .sit }!          // "Sit" — don't feed my opponent
        } else if Int.random(in: 0..<100) < 25 {
            phrase = BughouseController.phrases.first { $0.bias == .go }!           // "Go" — trade & feed me
        } else {
            let wants: [PieceKind] = [.knight, .bishop, .rook, .queen]
            let k = wants.randomElement()!
            phrase = BughouseController.phrases.first { $0.bias == .need(k) }!      // "+N" etc.
        }
        say(phrase, from: seat)
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
    /// `text` is the shorthand shown on the button & in the log; `hint` is the plain meaning.
    public struct Phrase: Identifiable, Sendable {
        public let id: Int
        public let text: String     // shorthand, e.g. "+N", "Sit"
        public let hint: String     // meaning, e.g. "send me a knight"
        let bias: PartnerCommand?
        init(_ id: Int, _ text: String, _ hint: String, _ bias: PartnerCommand? = nil) {
            self.id = id; self.text = text; self.hint = hint; self.bias = bias
        }
    }

    /// Standard FICS-style bughouse shorthand (clean subset) everyone can say.
    public static let phrases: [Phrase] = [
        .init(0,  "Sit",  "sit / don't trade", .sit),   .init(1,  "Go",   "trade & attack", .go),
        .init(2,  "Fast", "play fast"),                  .init(3,  "Time", "low on time"),
        .init(4,  "++",   "I'm winning"),                .init(5,  "--",   "I'm losing"),
        .init(6,  "+Q",   "send me a queen", .need(.queen)),  .init(7,  "-Q",  "I'm giving up a queen"),
        .init(8,  "+R",   "send me a rook", .need(.rook)),    .init(9,  "-R",  "I'm giving up a rook"),
        .init(10, "+N",   "send me a knight", .need(.knight)),.init(11, "-N",  "I'm giving up a knight"),
        .init(12, "+B",   "send me a bishop", .need(.bishop)),.init(13, "-B",  "I'm giving up a bishop"),
        .init(14, "+P",   "send me a pawn", .need(.pawn)),    .init(15, "-P",  "I'm giving up a pawn"),
        .init(16, "OK",   "okay"),                       .init(17, "OK now", "okay, now"),
        .init(18, "Hard", "this is hard"),               .init(19, "Coming", "help is coming"),
        .init(20, "Maybe","maybe"),                      .init(21, "I sit", "I'll sit", .sit),
        .init(22, "Mates me", "they have mate on me"),   .init(23, "Mates him", "I have mate"),
        .init(24, "I dead", "I'm lost"),                 .init(25, "Opp dead", "opponent is lost"),
        .init(26, "Yes",  "yes"),                        .init(27, "No",   "no"),
        .init(28, "Tell me go", "tell me when to go"),   .init(29, "Tell u go", "I'll tell you to go", .go),
        .init(30, "Keep check", "keep them in check"),   .init(31, "Nevermind", "never mind"),
        .init(32, "We up", "we're up material"),         .init(33, "We down", "we're down material"),
        .init(34, "U get", "you take it"),               .init(35, "He gets", "let them take it"),
        .init(36, "Watchout", "watch out!"),             .init(37, "Feed me", "send me pieces", .go),
        .init(38, "Lag", "I'm lagging"),
    ]

    /// Say a phrase out loud (everyone sees it). If it carries a request and the speaker's
    /// partner is a computer, it nudges that bot's play.
    public func say(_ phrase: Phrase, from seat: BughouseSeat? = nil) {
        let speaker = seat ?? primaryHumanSeat ?? .b1White
        let who = (speaker == primaryHumanSeat) ? "You" : speaker.label
        let line = "\(who): \(phrase.text)"
        chat.append(line)
        if chat.count > 30 { chat.removeFirst(chat.count - 30) }
        if let bias = phrase.bias {
            let mate = partner(of: speaker)
            if case .computer = seats[mate] { botRequest[mate] = bias }
        }
        net?.sendChat(line)   // table talk is public across all devices
    }

    /// Append table talk that arrived from another device.
    public func receiveChat(_ line: String) {
        chat.append(line)
        if chat.count > 30 { chat.removeFirst(chat.count - 30) }
    }

    /// Client: adopt the host's full game state (replay its move log + clocks). Used on join.
    public func loadState(moveLog log: [BughouseLogEntry], baseTime base: Double, increment inc: Double, clocks: [Double]) {
        aiTasks.forEach { $0?.cancel() }; tickTask?.cancel()
        baseTime = base; increment = inc
        boards = BughouseController.freshBoards()
        moveLog = []
        clock = [Double](repeating: base, count: 4)
        replayLog(log)
        if clocks.count == 4 { clock = clocks }
        status = .ongoing
        startTicking()
    }

    public var resultText: String {
        switch status {
        case .ongoing: return ""
        case .win(let team, let why): return "Team \(team == 0 ? "A" : "B") wins — \(why)"
        case .draw(let why): return "Draw — \(why)"
        }
    }
}
