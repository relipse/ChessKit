import SwiftUI
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

// `BugPacket` (the shared wire packet) is defined in BughouseOnlineService.swift so both the
// nearby (Multipeer) and online (server-relay) transports can use it.

/// Host-authoritative Bughouse over MultipeerConnectivity: the host runs the real game and the
/// bots/clocks; joiners are thin clients that own one seat each and mirror the host. All peers
/// share one mesh session (`kcbughouse`), so table-talk and moves reach everyone.
@MainActor
public final class BughouseNearbyService: NSObject, ObservableObject, BughouseNet {
    public enum Phase: Equatable { case idle, hostLobby, browse, waiting, playing, disconnected }

    @Published public var phase: Phase = .idle
    @Published public var foundHosts: [MCPeerID] = []
    @Published public var lobbyPeers: [String] = []           // host: connected joiners
    @Published public private(set) var controller: BughouseController?
    @Published public var mySeat: BughouseSeat?               // client
    @Published public private(set) var planVersion = 0        // bumped when the host edits seats

    /// Live status of a seat in the host lobby.
    public enum SeatStatus: Equatable { case you, joiner(String), open, bot(Int) }
    public func status(of seat: BughouseSeat) -> SeatStatus {
        switch hostPlan[seat.rawValue] {
        case .human: return .you
        case .computer(let d): return .bot(d.level)
        case .none:
            if let p = peerSeat.first(where: { $0.value == seat }) { return .joiner(p.key.displayName) }
            return .open
        }
    }
    /// How many seats are still waiting for a nearby player (open, unclaimed).
    public var humansWaiting: Int { BughouseSeat.allCases.filter { status(of: $0) == .open }.count }
    /// Every seat is filled (you / a joiner / a bot) — ready to begin with no surprises.
    public var allSeatsFilled: Bool { humansWaiting == 0 }
    /// Host: drop a bot into an open seat (or change one's level).
    public func assignBot(_ seat: BughouseSeat, level: Int) {
        hostPlan[seat.rawValue] = .computer(Difficulty(level: level)); planVersion += 1
    }
    /// Host: re-open a bot seat to wait for a nearby player again.
    public func reopenSeat(_ seat: BughouseSeat) {
        if case .computer = hostPlan[seat.rawValue] { hostPlan[seat.rawValue] = nil; planVersion += 1 }
    }
    /// Host: swap the two seats' occupants (you / a joiner / a bot / empty), re-syncing any
    /// affected joiner to its new seat so the host can arrange the table freely.
    public func swapSeats(_ a: BughouseSeat, _ b: BughouseSeat) {
        guard a != b else { return }
        hostPlan.swapAt(a.rawValue, b.rawValue)
        let aPeers = peerSeat.filter { $0.value == a }.map(\.key)
        let bPeers = peerSeat.filter { $0.value == b }.map(\.key)
        for p in aPeers { peerSeat[p] = b }
        for p in bPeers { peerSeat[p] = a }
        for p in (aPeers + bPeers) {
            if let newSeat = peerSeat[p] {
                send(BugPacket(kind: .assign, seat: newSeat.rawValue, seatLevels: seatLevels(),
                               baseTime: baseTime, increment: increment), to: p)
            }
        }
        lobbyPeers = peerSeat.map { "\($0.value.label) — \($0.key.displayName)" }
        planVersion += 1
    }

    /// Host seat plan: per seat, nil = open for a nearby player, .human = the host, .computer = bot.
    public var hostPlan: [SeatPlayer?] = [.human, nil, nil, .computer(.medium)]
    public var baseTime: Double = 180
    public var increment: Double = 2
    /// Strength used for any open seat no nearby player claimed.
    public var fallbackDifficulty: Difficulty = .medium

    private let serviceType = "kcbughouse"
    private let myPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var isHost = false
    private var peerSeat: [MCPeerID: BughouseSeat] = [:]      // host: seat each joiner owns
    private var pendingLevels: [Int]?                          // client: seat plan from host

    public init(displayName: String) {
        myPeerID = MCPeerID(displayName: String(displayName.prefix(60)))
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    // MARK: Host

    public func startHosting() {
        isHost = true; phase = .hostLobby
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }

    private var openSeats: [BughouseSeat] { BughouseSeat.allCases.filter { hostPlan[$0.rawValue] == nil } }

    private func seatLevels() -> [Int] {
        BughouseSeat.allCases.map { s in
            switch hostPlan[s.rawValue] {
            case .computer(let d): return max(1, min(10, d.level))
            default: return -1   // human (host or a remote joiner)
            }
        }
    }

    /// Begin the match (host). Builds the authoritative controller and tells every joiner.
    public func beginMatch(store: BughouseStore?) {
        let claimed = Set(peerSeat.values)
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases {
            switch hostPlan[s.rawValue] {
            case .human: seats[s] = .human                                   // the host's own seat
            case .computer(let d): seats[s] = .computer(d)                   // host configured a bot
            case .none:  seats[s] = claimed.contains(s) ? .human            // a nearby player took it
                                                        : .computer(fallbackDifficulty)  // nobody came → bot
            }
        }
        let c = BughouseController(seats: seats, store: store, baseTime: baseTime, increment: increment)
        c.role = .host
        c.localSeats = Set(BughouseSeat.allCases.filter { hostPlan[$0.rawValue] == .human })
        c.net = self
        controller = c
        phase = .playing
        broadcast(BugPacket(kind: .sync, seatLevels: levels(of: seats), baseTime: baseTime,
                            increment: increment, moveLog: c.moveLog, clocks: c.clock))
    }

    /// Per-seat wire levels from a resolved seat map (-1 human, 1…10 bot).
    private func levels(of seats: [BughouseSeat: SeatPlayer]) -> [Int] {
        BughouseSeat.allCases.map { if case .computer(let d) = seats[$0] { return max(1, min(10, d.level)) } else { return -1 } }
    }

    // MARK: Client

    public func startBrowsing() {
        isHost = false; phase = .browse
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }
    public func invite(_ peer: MCPeerID) { browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20) }

    public func stop() {
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        session.disconnect(); phase = .idle; foundHosts = []; lobbyPeers = []; peerSeat = [:]
    }

    // MARK: BughouseNet

    public func sendMoveToHost(board: Int, move: Move) { broadcast(BugPacket(kind: .moveRequest, board: board, move: move)) }
    public func broadcastMove(board: Int, move: Move) { broadcast(BugPacket(kind: .move, board: board, move: move)) }
    public func sendChat(_ line: String) { broadcast(BugPacket(kind: .chat, line: line)) }

    private func broadcast(_ p: BugPacket) {
        guard let data = try? JSONEncoder().encode(p), !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
    private func send(_ p: BugPacket, to peer: MCPeerID) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
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
        controller = c; phase = .playing
    }
}

extension BughouseNearbyService: MCSessionDelegate {
    nonisolated public func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if isHost {
                    if let seat = openSeats.first(where: { !peerSeat.values.contains($0) }) {
                        peerSeat[peerID] = seat
                        lobbyPeers = peerSeat.map { "\($0.value.label) — \($0.key.displayName)" }
                        // Tell this joiner its seat + the seat plan + time control.
                        send(BugPacket(kind: .assign, seat: seat.rawValue, seatLevels: seatLevels(),
                                       baseTime: baseTime, increment: increment), to: peerID)
                        // If the match is already running, sync them in.
                        if let c = controller {
                            send(BugPacket(kind: .sync, seatLevels: seatLevels(), baseTime: baseTime,
                                           increment: increment, moveLog: c.moveLog, clocks: c.clock), to: peerID)
                        }
                    }
                }
            case .notConnected:
                if isHost { peerSeat[peerID] = nil; lobbyPeers = peerSeat.map { "\($0.value.label) — \($0.key.displayName)" } }
                else if phase == .playing || phase == .waiting { phase = .disconnected }
            default: break
            }
        }
    }

    nonisolated public func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let p = try? JSONDecoder().decode(BugPacket.self, from: data) else { return }
        Task { @MainActor in handle(p) }
    }

    @MainActor private func handle(_ p: BugPacket) {
        switch p.kind {
        case .assign:
            if let sr = p.seat { mySeat = BughouseSeat(rawValue: sr) }
            pendingLevels = p.seatLevels
            if let b = p.baseTime { baseTime = b }; if let i = p.increment { increment = i }
            if phase == .browse { phase = .waiting }
        case .sync:
            if controller == nil { buildClientController(levels: p.seatLevels ?? pendingLevels ?? [],
                                                          base: p.baseTime ?? baseTime, inc: p.increment ?? increment) }
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
        }
    }

    nonisolated public func session(_ s: MCSession, didReceive st: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    nonisolated public func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with prog: Progress) {}
    nonisolated public func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at url: URL?, withError e: Error?) {}
}

extension BughouseNearbyService: MCNearbyServiceAdvertiserDelegate {
    nonisolated public func advertiser(_ a: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                       withContext c: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(self.openSeats.contains { !self.peerSeat.values.contains($0) }, self.session) }
    }
}

extension BughouseNearbyService: MCNearbyServiceBrowserDelegate {
    nonisolated public func browser(_ b: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo i: [String: String]?) {
        Task { @MainActor in if !foundHosts.contains(peerID) { foundHosts.append(peerID) } }
    }
    nonisolated public func browser(_ b: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in foundHosts.removeAll { $0 == peerID } }
    }
}

/// Observes the service and shows the lobby until a match is ready, then the game.
struct BughouseNearbyFlow: View {
    let brand: Brand
    @ObservedObject var appearance: Appearance
    @ObservedObject var service: BughouseNearbyService
    let store: BughouseStore?
    let onExit: () -> Void
    var body: some View {
        if let c = service.controller {
            BughouseGameView(brand: brand, appearance: appearance, controller: c, onExit: onExit)
        } else {
            BughouseNearbyLobby(brand: brand, service: service, store: store, onCancel: onExit)
        }
    }
}

/// Host or join a nearby Bughouse match.
struct BughouseNearbyLobby: View {
    let brand: Brand
    @ObservedObject var service: BughouseNearbyService
    let store: BughouseStore?
    let onCancel: () -> Void

    @State private var mode = 0                                  // 0 host · 1 join
    @State private var level = 4
    @State private var tc = 3   // default 10 min
    private let tcs: [(String, Double, Double)] = [("No timer", 0, 0), ("3 min", 180, 0), ("5 min", 300, 0), ("10 min", 600, 0), ("15 min", 900, 0)]

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $mode) { Text("Host").tag(0); Text("Join").tag(1) }
                    .pickerStyle(.segmented)
                if mode == 0 { hostSection } else { joinSection }
            }
            .navigationTitle("Play Nearby")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { service.stop(); onCancel() } } }
        }.tint(brand.accent)
    }

    @ViewBuilder private var hostSection: some View {
        if service.phase == .hostLobby {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title2).foregroundStyle(brand.accent).symbolEffect(.variableColor.iterative)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scanning room…").font(.headline)
                        Text("Open on Wi-Fi — nearby players can join.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            Section {
                if service.humansWaiting > 0 {
                    Label("Waiting for \(service.humansWaiting) more player\(service.humansWaiting == 1 ? "" : "s") to join…",
                          systemImage: "person.2.wave.2.fill").foregroundStyle(brand.accent)
                } else {
                    Label("All seats filled — ready to start!", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text("Your game is open on Wi-Fi — a friend taps Join Nearby to grab a seat. Impatient? Tap “Add bot” on any waiting seat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "ladybug.fill").foregroundStyle(brand.accent)
                    Text("The table").font(.headline)
                }
                Text("Partners sit across both boards (same team) — the two players on one board are opponents.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    lobbyBoard(0)
                    lobbyBoard(1)
                }.padding(.vertical, 4)
            }
            Section {
                Picker("Bot strength", selection: $level) { ForEach(1...10, id: \.self) { Text("Level \($0)").tag($0) } }
                Button { service.beginMatch(store: store) } label: {
                    Label("Begin Match", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                if service.humansWaiting > 0 {
                    Text("Beginning now fills the \(service.humansWaiting) waiting seat\(service.humansWaiting == 1 ? "" : "s") with a Level \(level) bot.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Section("Clock") {
                Picker("Time", selection: $tc) { ForEach(tcs.indices, id: \.self) { Text(tcs[$0].0).tag($0) } }
            }
            Section {
                Button {
                    service.hostPlan = [.human, nil, nil, nil]          // you + 3 seats open for nearby players
                    service.baseTime = tcs[tc].1; service.increment = tcs[tc].2
                    service.fallbackDifficulty = Difficulty(level: level)
                    service.startHosting()
                } label: { Label("Host Game", systemImage: "wifi").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                Text("You take one seat; the other three open up for nearby players. On the next screen you can drop a bot into any seat you don't want to wait for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A board in the lobby: the two opposing seats above & below a little chessboard.
    @ViewBuilder private func lobbyBoard(_ b: Int) -> some View {
        let top: BughouseSeat = b == 0 ? .b1Black : .b2White      // top edge (Team B)
        let bottom: BughouseSeat = b == 0 ? .b1White : .b2Black   // bottom edge (Team A)
        VStack(spacing: 6) {
            Text("Board \(b + 1)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            seatChip(top)
            miniBoard(b)
            seatChip(bottom)
        }.frame(maxWidth: .infinity)
    }

    /// A compact seat chip: colour dot, team, who's sitting, plus add-bot / swap actions.
    @ViewBuilder private func seatChip(_ s: BughouseSeat) -> some View {
        let teamColor: Color = s.team == 0 ? brand.accent : .gray
        HStack(spacing: 6) {
            Circle().fill(s.color == .white ? Color.white : Color.black)
                .frame(width: 12, height: 12).overlay(Circle().strokeBorder(.gray, lineWidth: 0.5))
            Text(s.team == 0 ? "A" : "B").font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white).frame(width: 17, height: 17).background(teamColor, in: Circle())
            Group {
                switch service.status(of: s) {
                case .you: Label("You", systemImage: "person.fill").foregroundStyle(brand.accent)
                case .joiner(let n): Label(n, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .bot(let lv): Label("Bot Lv\(lv)", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                case .open: Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
                }
            }.font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            switch service.status(of: s) {
            case .open: Button { service.assignBot(s, level: level) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).foregroundStyle(brand.accent)
            case .bot: Button { service.reopenSeat(s) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            default: EmptyView()
            }
            Menu {
                ForEach(BughouseSeat.allCases.filter { $0 != s }) { o in
                    Button("Swap with Bd\(o.board + 1) \(o.color == .white ? "White" : "Black")") { service.swapSeats(s, o) }
                }
            } label: { Image(systemName: "arrow.left.arrow.right") }.buttonStyle(.borderless).font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(teamColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(teamColor.opacity(0.45), lineWidth: 1))
    }

    /// A small decorative chessboard with the opening position — eye-candy for the lobby.
    private func miniBoard(_ b: Int) -> some View {
        let dark = b == 0 ? Color(red: 0.71, green: 0.53, blue: 0.39) : Color(red: 0.46, green: 0.59, blue: 0.34)
        let light = b == 0 ? Color(red: 0.94, green: 0.85, blue: 0.71) : Color(red: 0.93, green: 0.93, blue: 0.82)
        let pieces = ["♜","♞","♝","♛","♚","♝","♞","♜"]
        func glyph(_ r: Int, _ c: Int) -> (String, Color) {
            switch r {
            case 0: return (pieces[c], Color(white: 0.12)); case 1: return ("♟", Color(white: 0.12))
            case 6: return ("♟", .white); case 7: return (pieces[c], .white)
            default: return ("", .clear)
            }
        }
        return VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { c in
                        let (g, gc) = glyph(r, c)
                        ZStack {
                            Rectangle().fill((r + c) % 2 == 0 ? light : dark)
                            Text(g).font(.system(size: 14))
                                .foregroundStyle(gc)
                                .shadow(color: gc == .white ? .black.opacity(0.55) : .white.opacity(0.35), radius: 0.5)
                        }.frame(width: 19, height: 19)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder private var joinSection: some View {
        Section {
            if service.phase != .browse && service.phase != .waiting {
                Button { service.startBrowsing() } label: { Label("Find a Host", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
        }
        if service.phase == .waiting {
            Section { Label("Joined as \(service.mySeat?.label ?? "a seat") — waiting for the host to start…", systemImage: "hourglass") }
        } else if service.phase == .browse {
            Section("Nearby hosts") {
                if service.foundHosts.isEmpty { HStack { ProgressView(); Text("Searching…") } }
                ForEach(service.foundHosts, id: \.self) { peer in
                    Button { service.invite(peer) } label: { Label(peer.displayName, systemImage: "person.crop.circle.badge.plus") }
                }
            }
        }
    }
}
#endif
