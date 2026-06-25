import SwiftUI
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Wire packet for a nearby (multi-device) Bughouse match.
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

    /// Host seat plan: per seat, nil = open for a nearby player, .human = the host, .computer = bot.
    public var hostPlan: [SeatPlayer?] = [.human, nil, nil, .computer(.medium)]
    public var baseTime: Double = 180
    public var increment: Double = 2

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
        var seats: [BughouseSeat: SeatPlayer] = [:]
        for s in BughouseSeat.allCases { seats[s] = hostPlan[s.rawValue] ?? .human }   // open → human (remote)
        let c = BughouseController(seats: seats, store: store, baseTime: baseTime, increment: increment)
        c.role = .host
        c.localSeats = Set(BughouseSeat.allCases.filter { hostPlan[$0.rawValue] == .human })
        c.net = self
        controller = c
        phase = .playing
        broadcast(BugPacket(kind: .sync, seatLevels: seatLevels(), baseTime: baseTime,
                            increment: increment, moveLog: c.moveLog, clocks: c.clock))
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
    @State private var plan = [0, 2, 2, 1]                       // per seat: 0 You · 1 Bot · 2 Open
    @State private var level = 4
    @State private var tc = 1
    private let tcs: [(String, Double, Double)] = [("1|0", 60, 0), ("2|0", 120, 0), ("3|2", 180, 2), ("5|0", 300, 0)]

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
            Section("Waiting for players") {
                if service.lobbyPeers.isEmpty { Text("Open seats are advertised. Ask a friend to tap Join nearby on their device.").font(.callout).foregroundStyle(.secondary) }
                ForEach(service.lobbyPeers, id: \.self) { Label($0, systemImage: "person.fill.checkmark") }
            }
            Section {
                Button { service.beginMatch(store: store) } label: {
                    Label("Begin Match", systemImage: "play.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Text("Open seats with no one in them are played by the computer.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Section("Seats") {
                ForEach(BughouseSeat.allCases) { s in
                    Picker(s.label, selection: Binding(get: { plan[s.rawValue] }, set: { plan[s.rawValue] = $0 })) {
                        Text("You").tag(0); Text("Computer").tag(1); Text("Nearby player").tag(2)
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
                        switch plan[s.rawValue] { case 0: return .human; case 1: return .computer(Difficulty(level: level)); default: return nil }
                    }
                    service.baseTime = tcs[tc].1; service.increment = tcs[tc].2
                    service.startHosting()
                } label: { Label("Host Game", systemImage: "wifi").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                Text("Set at least one seat to “Nearby player”, then friends on the same Wi-Fi can join.").font(.caption).foregroundStyle(.secondary)
            }
        }
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
