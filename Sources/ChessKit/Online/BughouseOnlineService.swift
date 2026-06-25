import SwiftUI

/// Shared wire packet for a multi-device Bughouse match — used by BOTH transports:
/// the nearby (MultipeerConnectivity) service and this online (server-relay) service.
struct BugPacket: Codable {
    enum Kind: String, Codable { case assign, sync, moveRequest, move, chat }
    var kind: Kind
    var board: Int?
    var move: Move?
    var line: String?
    var seat: Int?              // assign: the recipient's seat
    var seatLevels: [Int]?      // per seat: -1 = human, 1…10 = computer level
    var baseTime: Double?
    var increment: Double?
    var moveLog: [BughouseLogEntry]?
    var clocks: [Double]?
}

/// Host-authoritative online Bughouse: the host runs the real game + bots + clocks and broadcasts
/// authoritative state; guests own one seat each and mirror the host. Transport is the server's
/// append-only event relay (BugPackets as opaque JSON), so it reuses the exact `BughouseNet` flow
/// the nearby (Multipeer) service uses — only the wire is swapped from the mesh to kinsman.cc.
@MainActor
public final class BughouseOnlineService: ObservableObject, BughouseNet {
    public enum Phase: Equatable { case setup, hostLobby, joining, waiting, playing, error }

    @Published public var phase: Phase = .setup
    @Published public private(set) var controller: BughouseController?
    @Published public var inviteCode: String?
    @Published public var seatNames: [String?] = [nil, nil, nil, nil]   // host lobby: who's in each seat
    @Published public var errorText: String?

    /// Host seat plan: per seat, .human = the host, .computer = a bot, nil = open for an online guest.
    public var hostPlan: [SeatPlayer?] = [.human, nil, nil, .computer(.medium)]
    public var baseTime: Double = 600
    public var increment: Double = 0
    public var fallbackDifficulty: Difficulty = .medium

    private let online = ChessOnline.shared
    private let store: BughouseStore?
    private var gameId: String?
    private var isHost = false
    private var mySeat: BughouseSeat?
    private var cursor = 0
    private var pollTask: Task<Void, Never>?
    private var lobbyTask: Task<Void, Never>?

    public init(store: BughouseStore?) { self.store = store }

    private var myUserId: String? { online.userId }

    // MARK: Host

    public func host() async {
        guard let g = await online.createGame(variant: "bughouse", base: Int(baseTime), increment: Int(increment)) else {
            errorText = online.lastError ?? "Could not create the game."; phase = .error; return
        }
        gameId = g.id; inviteCode = g.code; isHost = true; mySeat = BughouseSeat(rawValue: 0)
        hostPlan[0] = .human                      // the host always owns seat 0 on the server
        phase = .hostLobby
        startPolling(); startLobbyWatch()
    }

    /// Begin the match (host): resolve seats from server occupancy, lock open seats to bots, build the
    /// authoritative controller and broadcast the opening state to everyone.
    public func begin() async {
        guard let gid = gameId else { return }
        let detail = await online.gameSeats(gameId: gid)
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases {
            switch hostPlan[s.rawValue] {
            case .human: seats[s] = .human
            case .computer(let d): seats[s] = .computer(d)
            case .none:
                if let occ = detail.first(where: { $0.index == s.rawValue }), occ.name != nil {
                    seats[s] = .human                                   // a guest claimed this open seat
                } else {
                    seats[s] = .computer(fallbackDifficulty)            // nobody came → bot
                    await online.seatSet(gameId: gid, seat: s.rawValue, bot: true, level: fallbackDifficulty.level)
                }
            }
        }
        await online.startGame(gameId: gid)
        let c = BughouseController(seats: seats, store: store, baseTime: baseTime, increment: increment)
        c.role = .host
        c.localSeats = Set(BughouseSeat.allCases.filter { hostPlan[$0.rawValue] == .human })
        c.net = self
        controller = c
        lobbyTask?.cancel()
        phase = .playing
        post(BugPacket(kind: .sync, seatLevels: levels(of: seats), baseTime: baseTime,
                       increment: increment, moveLog: c.moveLog, clocks: c.clock))
    }

    // MARK: Guest

    public func join(code: String) async {
        phase = .joining
        guard let r = await online.joinGame(code: code.trimmingCharacters(in: .whitespaces)) else {
            errorText = online.lastError ?? "Could not join that game."; phase = .error; return
        }
        gameId = r.gameId; mySeat = BughouseSeat(rawValue: r.seat); isHost = false
        phase = .waiting
        startPolling()
    }

    // MARK: BughouseNet (transport)

    public func sendMoveToHost(board: Int, move: Move) { post(BugPacket(kind: .moveRequest, board: board, move: move)) }
    public func broadcastMove(board: Int, move: Move) { post(BugPacket(kind: .move, board: board, move: move)) }
    public func sendChat(_ line: String) { post(BugPacket(kind: .chat, line: line)) }

    private func post(_ p: BugPacket) {
        guard let gid = gameId, let data = try? JSONEncoder().encode(p),
              let s = String(data: data, encoding: .utf8) else { return }
        Task { _ = await online.eventPost(gameId: gid, kind: "bug", payload: s) }
    }

    // MARK: Relay loop

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                guard let gid = self.gameId else { break }
                if let r = await ChessOnline.shared.eventPoll(gameId: gid, since: self.cursor) {
                    for e in r.events {
                        self.cursor = max(self.cursor, e.id)
                        if e.byUser == self.myUserId { continue }      // skip my own echoes
                        if let d = e.payload.data(using: .utf8),
                           let p = try? JSONDecoder().decode(BugPacket.self, from: d) { self.handle(p) }
                    }
                    if r.status == "finished" { /* keep controller for review */ }
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    private func startLobbyWatch() {
        lobbyTask?.cancel()
        lobbyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let gid = self.gameId, self.phase == .hostLobby else { break }
                let detail = await ChessOnline.shared.gameSeats(gameId: gid)
                var names: [String?] = [nil, nil, nil, nil]
                for d in detail where d.index >= 0 && d.index < 4 {
                    names[d.index] = d.isBot ? "Computer" : d.name
                }
                self.seatNames = names
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func handle(_ p: BugPacket) {
        switch p.kind {
        case .sync:
            if controller == nil {
                buildClientController(levels: p.seatLevels ?? [], base: p.baseTime ?? baseTime, inc: p.increment ?? increment)
            }
            if let c = controller, c.role == .client {
                c.loadState(moveLog: p.moveLog ?? [], baseTime: p.baseTime ?? baseTime,
                            increment: p.increment ?? increment, clocks: p.clocks ?? [])
            }
        case .moveRequest:
            if isHost, let b = p.board, let m = p.move { controller?.receivePeerMove(board: b, m) }
        case .move:
            if !isHost, let b = p.board, let m = p.move { controller?.receiveHostMove(board: b, m) }
        case .chat:
            if let line = p.line { controller?.receiveChat(line) }
        case .assign:
            break   // online: the seat comes from game_join, not an assign packet
        }
    }

    private func buildClientController(levels: [Int], base: Double, inc: Double) {
        guard let seat = mySeat else { return }
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases {
            let lv = s.rawValue < levels.count ? levels[s.rawValue] : -1
            seats[s] = lv < 0 ? .human : .computer(Difficulty(level: lv))
        }
        let c = BughouseController(seats: seats, store: nil, baseTime: base, increment: inc)
        c.role = .client; c.localSeats = [seat]; c.net = self
        controller = c
        phase = .playing
    }

    private func levels(of seats: [BughouseSeat: SeatPlayer]) -> [Int] {
        BughouseSeat.allCases.map { if case .computer(let d) = seats[$0] { return max(1, min(10, d.level)) } else { return -1 } }
    }

    public func stop() {
        pollTask?.cancel(); lobbyTask?.cancel()
        controller = nil; gameId = nil; cursor = 0; inviteCode = nil; phase = .setup
    }
}

// MARK: - Online flow + lobby UI

/// Account → paywall → Bughouse online lobby → live match. Reuses AccountView / PaywallView.
public struct BughouseInternetView: View {
    let brand: Brand
    @ObservedObject private var appearance: Appearance
    @ObservedObject private var online = ChessOnline.shared
    @StateObject private var service: BughouseOnlineService
    @Environment(\.dismiss) private var dismiss

    public init(brand: Brand, store: BughouseStore?, appearance: Appearance = .shared) {
        self.brand = brand
        self.appearance = appearance
        _service = StateObject(wrappedValue: BughouseOnlineService(store: store))
    }

    public var body: some View {
        Group {
            if let c = service.controller {
                BughouseGameView(brand: brand, appearance: appearance, controller: c, onExit: { service.stop() })
            } else {
                NavigationStack {
                    Group {
                        if !online.isSignedIn { AccountView(brand: brand) }
                        else if !online.entitled { PaywallView(brand: brand) }
                        else { BughouseOnlineLobby(brand: brand, service: service) }
                    }
                    .navigationTitle("Internet Game")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { service.stop(); dismiss() } }
                        if online.isSignedIn {
                            ToolbarItem(placement: .primaryAction) {
                                Menu {
                                    Button("Sign Out") { online.signOut() }
                                    Button("Delete Account", role: .destructive) { Task { await online.deleteAccount() } }
                                } label: { Image(systemName: "person.crop.circle") }
                            }
                        }
                    }
                }
            }
        }
        .tint(brand.accent)
        .task { await online.refreshEntitlement(); await online.loadProducts(brand.onlineProductIDs) }
    }
}

/// Host (configure seats + clock, share an invite code) or join (enter a code) an online Bughouse game.
struct BughouseOnlineLobby: View {
    let brand: Brand
    @ObservedObject var service: BughouseOnlineService

    @State private var mode = 0                  // 0 host · 1 join
    @State private var code = ""
    @State private var plan = [0, 2, 2, 1]       // seat: 0 You · 1 Computer · 2 Online player  (seat 0 fixed = You)
    @State private var level = 4
    @State private var tc = 3
    private let tcs: [(String, Double, Double)] = [("No timer", 0, 0), ("3 min", 180, 0), ("5 min", 300, 0), ("10 min", 600, 0), ("15 min", 900, 0)]

    var body: some View {
        Form {
            Picker("", selection: $mode) { Text("Host").tag(0); Text("Join").tag(1) }.pickerStyle(.segmented)
            if mode == 0 { hostSection } else { joinSection }
            if let e = service.errorText { Section { Text(e).foregroundStyle(.red).font(.callout) } }
        }
    }

    @ViewBuilder private var hostSection: some View {
        if service.phase == .hostLobby {
            Section("Invite") {
                if let code = service.inviteCode {
                    HStack {
                        Text(code).font(.system(.title2, design: .monospaced).weight(.bold))
                        Spacer()
                        ShareLink(item: "Join my Bughouse game in the Bughouse Chess app with code \(code)") {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Text("Share this code. Up to 3 friends can join; any open seat is played by the computer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Seats") {
                ForEach(BughouseSeat.allCases) { s in
                    HStack {
                        Label(s.label, systemImage: "chair.fill")
                        Spacer()
                        Text(service.seatNames[s.rawValue] ?? (s.rawValue == 0 ? "You" : "Open"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button { Task { await service.begin() } } label: {
                    Label("Begin Match", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
        } else {
            Section("Seats") {
                ForEach(BughouseSeat.allCases) { s in
                    if s.rawValue == 0 {
                        HStack { Label(s.label, systemImage: "person.fill"); Spacer(); Text("You").foregroundStyle(.secondary) }
                    } else {
                        Picker(s.label, selection: Binding(get: { plan[s.rawValue] }, set: { plan[s.rawValue] = $0 })) {
                            Text("Computer").tag(1); Text("Online player").tag(2)
                        }
                    }
                }
            }
            Section("Clock") {
                Picker("Time", selection: $tc) { ForEach(tcs.indices, id: \.self) { Text(tcs[$0].0).tag($0) } }
                if plan.contains(1) {
                    Picker("Computer level", selection: $level) { ForEach(1...10, id: \.self) { Text("\($0)").tag($0) } }
                }
            }
            Section {
                Button {
                    service.hostPlan = BughouseSeat.allCases.map { s in
                        if s.rawValue == 0 { return .human }
                        switch plan[s.rawValue] { case 1: return .computer(Difficulty(level: level)); default: return nil }
                    }
                    service.baseTime = tcs[tc].1; service.increment = tcs[tc].2
                    service.fallbackDifficulty = Difficulty(level: level)
                    Task { await service.host() }
                } label: { Label("Host Game", systemImage: "globe").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                Text("Set seats to “Online player” for friends to join with your code. Any seat nobody takes is played by the computer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var joinSection: some View {
        if service.phase == .waiting {
            Section { Label("Joined — waiting for the host to start the match…", systemImage: "hourglass") }
        } else {
            Section("Invite code") {
                TextField("8-character code", text: $code).textCase(.uppercase).autocorrectionDisabled()
                Button { Task { await service.join(code: code) } } label: {
                    Label("Join Game", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).disabled(code.count < 4)
            }
            Section { Text("Ask the host for their invite code. You'll be seated automatically and the match starts when the host begins.")
                .font(.caption).foregroundStyle(.secondary) }
        }
    }
}
